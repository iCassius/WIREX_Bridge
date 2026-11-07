//go:build windows

package main

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// releaseVersionPattern is shared by `package` and `package-gui`.
var releaseVersionPattern = regexp.MustCompile(`^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$`)

const guiProvenanceFile = "gui-build-provenance.json"

// guiProvenance mirrors the JSON written by tools/build-gui.ps1.
type guiProvenance struct {
	SchemaVersion int    `json:"schema_version"`
	DevBuild      bool   `json:"dev_build"`
	Result        string `json:"result"`
	Source        struct {
		Commit    string `json:"commit"`
		TreeClean bool   `json:"tree_clean"`
	} `json:"source"`
	ImGui struct {
		Version string `json:"version"`
		Path    string `json:"path"`
	} `json:"imgui"`
	Compiler json.RawMessage `json:"compiler"`
	Output   struct {
		Directory   string `json:"directory"`
		Path        string `json:"path"`
		LengthBytes int64  `json:"length_bytes"`
		Sha256      string `json:"sha256"`
	} `json:"output"`
}

func readGUIProvenance(dir string) (guiProvenance, error) {
	var p guiProvenance
	b, err := os.ReadFile(filepath.Join(dir, guiProvenanceFile))
	if err != nil {
		return p, fmt.Errorf("读取 %s 失败：%w", filepath.Join(dir, guiProvenanceFile), err)
	}
	b = []byte(strings.TrimPrefix(string(b), "\ufeff"))
	if err := json.Unmarshal(b, &p); err != nil {
		return p, fmt.Errorf("无法解析 %s：%w", filepath.Join(dir, guiProvenanceFile), err)
	}
	return p, nil
}

var guiBuildDirName = regexp.MustCompile(`^wirex-gui-[0-9a-f]{7}(-dirty)?-(\d{8}-\d{6})$`)

// sortGUIBuildDirs orders build/_work/wirex-gui-* names newest first by their
// embedded UTC timestamp; non-matching names are dropped.
func sortGUIBuildDirs(names []string) []string {
	var out []string
	for _, n := range names {
		if guiBuildDirName.MatchString(n) {
			out = append(out, n)
		}
	}
	stamp := func(n string) string { return guiBuildDirName.FindStringSubmatch(n)[2] }
	sort.SliceStable(out, func(i, j int) bool { return stamp(out[i]) > stamp(out[j]) })
	return out
}

func shortCommit(c string) string {
	if len(c) > 7 {
		return c[:7]
	}
	return c
}

// findGUIBuild returns the newest release GUI build for head. Dirty builds are
// only considered when allowDirty is set.
func findGUIBuild(root, head string, allowDirty bool) (string, guiProvenance, error) {
	entries, err := os.ReadDir(workRoot(root))
	if err != nil {
		return "", guiProvenance{}, fmt.Errorf("读取 build/_work 失败：%w", err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	for _, n := range sortGUIBuildDirs(names) {
		dir := filepath.Join(workRoot(root), n)
		p, err := readGUIProvenance(dir)
		if err != nil {
			continue
		}
		if p.Result != "passed" || p.DevBuild || p.Source.Commit != head {
			continue
		}
		if !p.Source.TreeClean && !allowDirty {
			continue
		}
		if info, err := os.Stat(filepath.Join(dir, "WirexBridge.exe")); err != nil || !info.Mode().IsRegular() {
			continue
		}
		return dir, p, nil
	}
	return "", guiProvenance{}, fmt.Errorf("build/_work 下没有当前 HEAD（%s）的正式版 GUI 构建：需要 dev_build=false、提交匹配且工作树干净；请先运行 `wirex build --gui --release`。若工作树有未提交改动，可加 --allow-dirty 使用带 dirty 标记的构建", shortCommit(head))
}

// validateGUIBuild enforces the release gates on a GUI build directory.
func validateGUIBuild(dir, head string, allowDirty bool) (guiProvenance, error) {
	p, err := readGUIProvenance(dir)
	if err != nil {
		return p, err
	}
	if p.Result != "passed" {
		return p, fmt.Errorf("GUI 构建未通过（result=%q）：%s", p.Result, dir)
	}
	if p.DevBuild {
		return p, fmt.Errorf("拒绝打包开发版 GUI 构建（dev_build=true）：%s\n请用 `wirex build --gui --release` 重新构建", dir)
	}
	if p.Source.Commit != head {
		return p, fmt.Errorf("GUI 构建提交不匹配：构建为 %s，当前 HEAD 为 %s；请在当前提交重新运行 `wirex build --gui --release`",
			shortCommit(p.Source.Commit), shortCommit(head))
	}
	if !p.Source.TreeClean {
		if !allowDirty {
			return p, fmt.Errorf("GUI 构建来自脏工作树（source.tree_clean=false）：%s\n请提交改动后重新运行 `wirex build --gui --release`，或加 --allow-dirty 生成带 dirty 标记的包", dir)
		}
		fmt.Println("WARN：GUI 构建来自脏工作树（--allow-dirty），manifest 将记录 dirty=true")
	}
	exe := filepath.Join(dir, "WirexBridge.exe")
	info, err := os.Stat(exe)
	if err != nil || !info.Mode().IsRegular() {
		return p, fmt.Errorf("GUI 构建目录缺少 WirexBridge.exe：%s", exe)
	}
	if p.Output.Sha256 != "" {
		sum, err := fileSha256(exe)
		if err != nil {
			return p, fmt.Errorf("计算 WirexBridge.exe SHA-256 失败：%w", err)
		}
		if !strings.EqualFold(sum, p.Output.Sha256) {
			return p, fmt.Errorf("WirexBridge.exe 的 SHA-256 与 provenance 不符：实际 %s，provenance %s", sum, p.Output.Sha256)
		}
	}
	return p, nil
}

// ---------------------------------------------------------------- staging

type stagedSource struct {
	Rel string // forward-slash path inside the package
	Src string // absolute source path
}

// guiLicenseSources lists the licenses that must ship with the GUI. imgui's
// NOTICE.md is optional so the inventory still matches when upstream drops it.
func guiLicenseSources(repoRoot string) ([]stagedSource, error) {
	required := []struct{ rel, src string }{
		{"licenses/dmr_signal/COPYING.GPL-3.0.txt", "third_party/dmr_signal/COPYING.GPL-3.0.txt"},
		{"licenses/dmr_signal/NOTICE.md", "third_party/dmr_signal/NOTICE.md"},
		{"licenses/droidstar_mbe/COPYING.GPL-3.0.txt", "third_party/droidstar_mbe/COPYING.GPL-3.0.txt"},
		{"licenses/droidstar_mbe/ISC-NOTICE.txt", "third_party/droidstar_mbe/ISC-NOTICE.txt"},
		{"licenses/imgui/LICENSE.txt", "third_party/imgui/LICENSE.txt"},
	}
	out := make([]stagedSource, 0, len(required)+1)
	for _, r := range required {
		src := filepath.Join(repoRoot, filepath.FromSlash(r.src))
		info, err := os.Stat(src)
		if err != nil || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("缺少许可证文件 %s：%w", r.src, err)
		}
		out = append(out, stagedSource{r.rel, src})
	}
	optional := stagedSource{"licenses/imgui/NOTICE.md", filepath.Join(repoRoot, "third_party", "imgui", "NOTICE.md")}
	if info, err := os.Stat(optional.Src); err == nil && info.Mode().IsRegular() {
		out = append(out, optional)
	}
	return out, nil
}

// stageGUIPackage rebuilds stageDir from scratch with exactly the release
// inventory and returns the staged forward-slash relative paths (sorted).
func stageGUIPackage(guiDir, notesPath, repoRoot, stageDir string) ([]string, error) {
	exe := filepath.Join(guiDir, "WirexBridge.exe")
	if info, err := os.Stat(exe); err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("GUI 构建目录缺少 WirexBridge.exe：%s", exe)
	}
	if info, err := os.Stat(notesPath); err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("找不到发布说明 %s（用 --notes 指定）", notesPath)
	}
	licenses, err := guiLicenseSources(repoRoot)
	if err != nil {
		return nil, err
	}

	copies := append([]stagedSource{{"WirexBridge.exe", exe}, {"README.md", notesPath}}, licenses...)
	expected := make([]string, 0, len(copies))
	for _, c := range copies {
		expected = append(expected, c.Rel)
	}

	if err := os.RemoveAll(stageDir); err != nil {
		return nil, fmt.Errorf("清理暂存目录失败：%w", err)
	}
	if err := os.MkdirAll(stageDir, 0o755); err != nil {
		return nil, fmt.Errorf("创建暂存目录失败：%w", err)
	}
	for _, c := range copies {
		dst := filepath.Join(stageDir, filepath.FromSlash(c.Rel))
		if err := copyFile(dst, c.Src); err != nil {
			return nil, fmt.Errorf("复制 %s 失败：%w", c.Rel, err)
		}
	}

	inventory, err := collectInventory(stageDir)
	if err != nil {
		return nil, err
	}
	if err := assertInventory(inventory, expected); err != nil {
		return nil, err
	}
	return inventory, nil
}

func copyFile(dst, src string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// collectInventory returns every regular file under dir as sorted forward-slash
// relative paths; symlinks and other non-regular entries are rejected.
func collectInventory(dir string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if !d.Type().IsRegular() {
			return fmt.Errorf("暂存目录包含非普通文件：%s", rel)
		}
		files = append(files, rel)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("扫描暂存目录失败：%w", err)
	}
	sort.Strings(files)
	return files, nil
}

// assertInventory requires got to equal want exactly (both sorted).
func assertInventory(got, want []string) error {
	w := append([]string(nil), want...)
	sort.Strings(w)
	if len(got) != len(w) {
		return fmt.Errorf("GUI 包清单不符：期望 %d 个文件，实际 %d 个\n期望：%v\n实际：%v", len(w), len(got), w, got)
	}
	for i := range w {
		if got[i] != w[i] {
			return fmt.Errorf("GUI 包清单不符：第 %d 项为 %q，期望 %q\n实际：%v", i+1, got[i], w[i], got)
		}
	}
	return nil
}

// ---------------------------------------------------------------- zip

// zipTimestamp is fixed so the same staged files always produce identical zip
// bytes (reproducible releases).
var zipTimestamp = time.Date(1980, 1, 1, 0, 0, 0, 0, time.UTC)

// writePackageZip writes files from stageDir under topFolder, in sorted order,
// with forward-slash entry names.
func writePackageZip(zipPath, topFolder, stageDir string, files []string) error {
	if err := os.MkdirAll(filepath.Dir(zipPath), 0o755); err != nil {
		return err
	}
	f, err := os.Create(zipPath)
	if err != nil {
		return err
	}
	zw := zip.NewWriter(f)
	sorted := append([]string(nil), files...)
	sort.Strings(sorted)
	for _, rel := range sorted {
		name := topFolder + "/" + rel
		if err := addZipFile(zw, name, filepath.Join(stageDir, filepath.FromSlash(rel))); err != nil {
			zw.Close()
			f.Close()
			return err
		}
	}
	if err := zw.Close(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func addZipFile(zw *zip.Writer, name, src string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	h := &zip.FileHeader{Name: name, Method: zip.Deflate, Modified: zipTimestamp}
	h.SetMode(0o644)
	h.UncompressedSize64 = uint64(info.Size())
	w, err := zw.CreateHeader(h)
	if err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	_, err = io.Copy(w, in)
	return err
}

// ---------------------------------------------------------------- manifest

type guiManifestFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	Sha256 string `json:"sha256"`
}

type guiManifestZip struct {
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	Sha256 string `json:"sha256"`
}

type guiManifestBuild struct {
	DevBuild        bool            `json:"dev_build"`
	Result          string          `json:"result"`
	SourceCommit    string          `json:"source_commit"`
	SourceTreeClean bool            `json:"source_tree_clean"`
	ImGuiVersion    string          `json:"imgui_version"`
	Compiler        json.RawMessage `json:"compiler,omitempty"`
	ExeSha256       string          `json:"exe_sha256"`
	ExeSize         int64           `json:"exe_size"`
}

type guiManifest struct {
	SchemaVersion int               `json:"schema_version"`
	Version       string            `json:"version"`
	GitCommit     string            `json:"git_commit"`
	Dirty         bool              `json:"dirty"`
	CreatedUTC    string            `json:"created_utc"`
	Build         guiManifestBuild  `json:"build"`
	Files         []guiManifestFile `json:"files"`
	Zip           guiManifestZip    `json:"zip"`
}

func manifestFiles(stageDir string, files []string) ([]guiManifestFile, error) {
	out := make([]guiManifestFile, 0, len(files))
	for _, rel := range files {
		p := filepath.Join(stageDir, filepath.FromSlash(rel))
		info, err := os.Stat(p)
		if err != nil {
			return nil, err
		}
		sum, err := fileSha256(p)
		if err != nil {
			return nil, err
		}
		out = append(out, guiManifestFile{Path: rel, Size: info.Size(), Sha256: sum})
	}
	return out, nil
}

func writeJSONFile(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

// ---------------------------------------------------------------- command

type packageGUIOptions struct {
	Version    string
	GUIDir     string
	Notes      string
	AllowDirty bool
}

func parsePackageGUIArgs(args []string) (packageGUIOptions, error) {
	fs := newFlagSet("package-gui")
	var o packageGUIOptions
	fs.StringVar(&o.Version, "version", "", "")
	fs.StringVar(&o.GUIDir, "gui-dir", "", "")
	fs.StringVar(&o.Notes, "notes", "", "")
	fs.BoolVar(&o.AllowDirty, "allow-dirty", false, "")
	if err := parseFlags(fs, args); err != nil {
		return o, err
	}
	if !releaseVersionPattern.MatchString(o.Version) {
		return o, usageError{fmt.Sprintf("--version 必须形如 v0.2.0 或 v0.2.0-test.2，实际 %q", o.Version)}
	}
	return o, nil
}

func resolveFrom(root, p string) string {
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Join(root, p)
}

func cmdPackageGUI(args []string) error {
	opts, err := parsePackageGUIArgs(args)
	if err != nil {
		return err
	}
	root, err := repoRoot()
	if err != nil {
		return err
	}
	head, err := gitHead(root)
	if err != nil {
		return err
	}

	guiDir := opts.GUIDir
	if guiDir != "" {
		guiDir = resolveFrom(root, guiDir)
	} else {
		guiDir, _, err = findGUIBuild(root, head, opts.AllowDirty)
		if err != nil {
			return err
		}
	}
	prov, err := validateGUIBuild(guiDir, head, opts.AllowDirty)
	if err != nil {
		return err
	}
	fmt.Println("GUI 构建：", guiDir)

	notes := opts.Notes
	if notes == "" {
		notes = filepath.Join("docs", "releases", opts.Version+".md")
	}
	notes = resolveFrom(root, notes)

	stageDir := filepath.Join(root, "build", "releases", opts.Version+"-gui")
	files, err := stageGUIPackage(guiDir, notes, root, stageDir)
	if err != nil {
		return err
	}
	fmt.Printf("暂存目录：%s（%d 个文件）\n", stageDir, len(files))

	distDir := filepath.Join(root, "build", "releases", opts.Version+"-gui-dist")
	if err := os.RemoveAll(distDir); err != nil {
		return fmt.Errorf("清理输出目录失败：%w", err)
	}
	if err := os.MkdirAll(distDir, 0o755); err != nil {
		return fmt.Errorf("创建输出目录失败：%w", err)
	}

	topFolder := "WIREX_Bridge_" + opts.Version
	zipName := topFolder + ".zip"
	zipPath := filepath.Join(distDir, zipName)
	if err := writePackageZip(zipPath, topFolder, stageDir, files); err != nil {
		return fmt.Errorf("生成 ZIP 失败：%w", err)
	}
	zipSum, err := fileSha256(zipPath)
	if err != nil {
		return fmt.Errorf("计算 ZIP SHA-256 失败：%w", err)
	}
	if err := os.WriteFile(filepath.Join(distDir, "SHA256SUMS.txt"), []byte(zipSum+"  "+zipName+"\n"), 0o644); err != nil {
		return fmt.Errorf("写入 SHA256SUMS.txt 失败：%w", err)
	}
	zipInfo, err := os.Stat(zipPath)
	if err != nil {
		return fmt.Errorf("读取 ZIP 信息失败：%w", err)
	}

	mfiles, err := manifestFiles(stageDir, files)
	if err != nil {
		return fmt.Errorf("生成 manifest 文件清单失败：%w", err)
	}
	exeSize := prov.Output.LengthBytes
	if exeSize == 0 {
		if info, statErr := os.Stat(filepath.Join(stageDir, "WirexBridge.exe")); statErr == nil {
			exeSize = info.Size()
		}
	}
	manifest := guiManifest{
		SchemaVersion: 1,
		Version:       opts.Version,
		GitCommit:     head,
		Dirty:         !prov.Source.TreeClean,
		CreatedUTC:    time.Now().UTC().Format(time.RFC3339),
		Build: guiManifestBuild{
			DevBuild:        prov.DevBuild,
			Result:          prov.Result,
			SourceCommit:    prov.Source.Commit,
			SourceTreeClean: prov.Source.TreeClean,
			ImGuiVersion:    prov.ImGui.Version,
			Compiler:        prov.Compiler,
			ExeSha256:       prov.Output.Sha256,
			ExeSize:         exeSize,
		},
		Files: mfiles,
		Zip:   guiManifestZip{Name: zipName, Size: zipInfo.Size(), Sha256: zipSum},
	}
	if manifest.Build.ExeSha256 == "" {
		if sum, sumErr := fileSha256(filepath.Join(stageDir, "WirexBridge.exe")); sumErr == nil {
			manifest.Build.ExeSha256 = sum
		}
	}
	if err := writeJSONFile(filepath.Join(distDir, "manifest.json"), manifest); err != nil {
		return fmt.Errorf("写入 manifest.json 失败：%w", err)
	}

	fmt.Println("\n== 包内容")
	for _, rel := range files {
		fmt.Println("  " + topFolder + "/" + rel)
	}
	fmt.Println("\n== 产物")
	fmt.Println("暂存目录：", stageDir)
	fmt.Println("ZIP：", zipPath)
	fmt.Println("SHA-256：", zipSum)
	fmt.Println("SHA256SUMS：", filepath.Join(distDir, "SHA256SUMS.txt"))
	fmt.Println("manifest：", filepath.Join(distDir, "manifest.json"))
	return nil
}
