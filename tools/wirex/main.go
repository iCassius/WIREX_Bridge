//go:build windows

// Command wirex is the WIREX Bridge maintenance CLI. The first version wraps the
// existing PowerShell build, test and packaging scripts so their release gates
// (clean tree checks, provenance, log validation) stay the single source of truth.
package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

const usage = `用法：wirex <命令> [参数]

命令：
  doctor                                   检查构建/运行环境
  build [--release|--debug] [--compile-only] [--cmake] [--with-launcher]
                                           构建 Native 核心（默认复用 tools/build-bm-bridge.ps1）
  test [--offline|--all] [--build-dir D] [--launcher P] [--run S]
                                           运行 Native 测试与 PowerShell 离线测试
  package --version V [--build-dir D] [--build-log L] [--launcher-dir D] [--fixture F] [--native-repo R]
  package --version V --zip [--package-root D]
                                           包装 tools/package-release.ps1 / ZipOnlyRelease
`

const approvedFixtureSha256 = "82e0085ccaccb769a83362c5b335ce6b9a0e3ae93afdf2ad4f46eb81f908577f"

// usageError marks argument errors so main can exit with code 2.
type usageError struct{ msg string }

func (e usageError) Error() string { return e.msg }

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "错误：", err)
		var ue usageError
		if errors.As(err, &ue) {
			fmt.Fprint(os.Stderr, "\n"+usage)
			os.Exit(2)
		}
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return usageError{"缺少命令"}
	}
	switch args[0] {
	case "doctor":
		return cmdDoctor(args[1:])
	case "build":
		return cmdBuild(args[1:])
	case "test":
		return cmdTest(args[1:])
	case "package":
		return cmdPackage(args[1:])
	case "help", "-h", "--help":
		fmt.Print(usage)
		return nil
	default:
		return usageError{"未知命令：" + args[0]}
	}
}

func newFlagSet(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return fs
}

func parseFlags(fs *flag.FlagSet, args []string) error {
	if err := fs.Parse(args); err != nil {
		return usageError{fmt.Sprintf("%s：%v", fs.Name(), err)}
	}
	if fs.NArg() > 0 {
		return usageError{fmt.Sprintf("%s：多余参数 %q", fs.Name(), fs.Args())}
	}
	return nil
}

// ---------------------------------------------------------------- repository

func repoRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("无法定位 Git 仓库根目录（请在 WIREX Bridge 仓库内运行）：%w", err)
	}
	root := filepath.Clean(strings.TrimSpace(string(out)))
	if _, err := os.Stat(filepath.Join(root, "tools", "build-bm-bridge.ps1")); err != nil {
		return "", fmt.Errorf("%s 不是 WIREX Bridge 仓库（缺少 tools/build-bm-bridge.ps1）：%w", root, err)
	}
	return root, nil
}

func gitOutput(root string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", root}, args...)...).Output()
	if err != nil {
		return "", fmt.Errorf("git %s 失败：%w", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out)), nil
}

func gitHead(root string) (string, error) {
	head, err := gitOutput(root, "rev-parse", "HEAD")
	if err != nil {
		return "", err
	}
	if !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(head) {
		return "", fmt.Errorf("无法识别的 HEAD 提交号：%q", head)
	}
	return head, nil
}

func workRoot(root string) string { return filepath.Join(root, "build", "_work") }

// ---------------------------------------------------------------- process runner

var (
	kernel32                = syscall.NewLazyDLL("kernel32.dll")
	procGetConsoleOutputCP  = kernel32.NewProc("GetConsoleOutputCP")
	procGetOEMCP            = kernel32.NewProc("GetOEMCP")
	procMultiByteToWideChar = kernel32.NewProc("MultiByteToWideChar")
)

const cpUTF8 = 65001

// consoleCodePage is the code page Windows PowerShell 5.1 uses for redirected
// output: the attached console's output CP, or the OEM CP for a fresh console.
func consoleCodePage() uint32 {
	if cp, _, _ := procGetConsoleOutputCP.Call(); cp != 0 {
		return uint32(cp)
	}
	cp, _, _ := procGetOEMCP.Call()
	return uint32(cp)
}

func decodeCodePage(cp uint32, b []byte) string {
	if cp == cpUTF8 || isASCII(b) {
		return string(b)
	}
	n, _, _ := procMultiByteToWideChar.Call(uintptr(cp), 0, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)), 0, 0)
	if n == 0 {
		return string(b)
	}
	buf := make([]uint16, n)
	procMultiByteToWideChar.Call(uintptr(cp), 0, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)),
		uintptr(unsafe.Pointer(&buf[0])), n)
	return string(utf16.Decode(buf))
}

func isASCII(b []byte) bool {
	for _, c := range b {
		if c >= 0x80 {
			return false
		}
	}
	return true
}

// runStreaming runs cmd with stdout+stderr merged, decodes each line from the
// given code page and writes it as UTF-8 to every sink. A non-zero exit code is
// returned as a value; only start/IO/timeout failures are errors.
func runStreaming(ctx context.Context, cmd *exec.Cmd, cp uint32, sinks ...io.Writer) (int, error) {
	r, w, err := os.Pipe()
	if err != nil {
		return -1, fmt.Errorf("创建输出管道失败：%w", err)
	}
	cmd.Stdout, cmd.Stderr = w, w
	if err := cmd.Start(); err != nil {
		r.Close()
		w.Close()
		return -1, fmt.Errorf("启动 %s 失败：%w", cmd.Path, err)
	}
	w.Close()
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 8*1024*1024)
	var sinkErr error
	for sc.Scan() {
		line := strings.TrimRight(decodeCodePage(cp, sc.Bytes()), "\r") + "\n"
		for _, s := range sinks {
			if _, err := io.WriteString(s, line); err != nil && sinkErr == nil {
				sinkErr = fmt.Errorf("写入输出失败：%w", err)
			}
		}
	}
	scanErr := sc.Err()
	if scanErr != nil {
		_, _ = io.Copy(io.Discard, r) // keep draining so the child cannot block on a full pipe
	}
	r.Close()
	waitErr := cmd.Wait()
	if ctx.Err() != nil {
		return -1, fmt.Errorf("%s 超时或被取消：%w", filepath.Base(cmd.Path), ctx.Err())
	}
	if scanErr != nil {
		return -1, fmt.Errorf("读取子进程输出失败：%w", scanErr)
	}
	if sinkErr != nil {
		return -1, sinkErr
	}
	var exitErr *exec.ExitError
	if errors.As(waitErr, &exitErr) {
		return exitErr.ExitCode(), nil
	}
	if waitErr != nil {
		return -1, fmt.Errorf("等待 %s 失败：%w", filepath.Base(cmd.Path), waitErr)
	}
	return 0, nil
}

// cmdLine builds a cmd.exe invocation with a verbatim command line; Go's default
// argument escaping (\") is not understood by cmd.exe.
func cmdLine(ctx context.Context, line string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "cmd.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `cmd.exe /d /s /c "` + line + `"`}
	return cmd
}

func powershellFile(ctx context.Context, root string, sta bool, script string, args ...string) *exec.Cmd {
	base := []string{"-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass"}
	if sta {
		base = append(base, "-STA")
	}
	base = append(base, "-File", script)
	cmd := exec.CommandContext(ctx, "powershell.exe", append(base, args...)...)
	cmd.Dir = root
	cmd.Env = windowsPowerShellEnv(os.Environ())
	return cmd
}

// windowsPowerShellEnv drops PSModulePath: when wirex is launched from pwsh 7,
// the inherited value puts PowerShell 7 modules first and Windows PowerShell 5.1
// then fails to load core cmdlets such as Get-FileHash. Unset, 5.1 rebuilds its
// own default module path.
func windowsPowerShellEnv(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		if !strings.HasPrefix(strings.ToUpper(kv), "PSMODULEPATH=") {
			out = append(out, kv)
		}
	}
	return out
}

func powershellEncoded(ctx context.Context, root, script string) *exec.Cmd {
	u := utf16.Encode([]rune(script))
	b := make([]byte, len(u)*2)
	for i, v := range u {
		b[2*i], b[2*i+1] = byte(v), byte(v>>8)
	}
	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-EncodedCommand", base64.StdEncoding.EncodeToString(b))
	cmd.Dir = root
	cmd.Env = windowsPowerShellEnv(os.Environ())
	return cmd
}

func psQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// ---------------------------------------------------------------- doctor

type checkStatus int

const (
	statusOK checkStatus = iota
	statusWarn
	statusFail
)

func (s checkStatus) String() string { return [...]string{"OK", "WARN", "FAIL"}[s] }

type checkResult struct {
	Name   string
	Status checkStatus
	Detail string
}

// doctorFailures counts FAIL results; any FAIL makes doctor exit non-zero.
func doctorFailures(results []checkResult) int {
	n := 0
	for _, r := range results {
		if r.Status == statusFail {
			n++
		}
	}
	return n
}

func cmdDoctor(args []string) error {
	if err := parseFlags(newFlagSet("doctor"), args); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	root, rootErr := repoRoot()
	var results []checkResult
	add := func(r checkResult) {
		results = append(results, r)
		fmt.Printf("[%-4s] %-22s %s\n", r.Status, r.Name, r.Detail)
	}

	add(checkVersionCmd(ctx, "Go", statusWarn, "go", "version"))
	add(checkVersionCmd(ctx, "Git", statusFail, "git", "--version"))
	add(checkCMake(ctx))
	vs := checkVisualStudio(ctx)
	for _, r := range vs {
		add(r)
	}
	add(checkWindowsPowerShell(ctx))
	add(checkSerialPorts(ctx))
	add(checkAudioEndpoints(ctx))
	if rootErr != nil {
		add(checkResult{"Git 仓库", statusFail, rootErr.Error()})
	} else {
		add(checkGitClean(root))
		add(checkFixture(root))
	}

	fails := doctorFailures(results)
	warns := 0
	for _, r := range results {
		if r.Status == statusWarn {
			warns++
		}
	}
	fmt.Printf("\n汇总：%d 项，FAIL %d，WARN %d\n", len(results), fails, warns)
	if fails > 0 {
		return fmt.Errorf("doctor 发现 %d 项 FAIL", fails)
	}
	return nil
}

func checkVersionCmd(ctx context.Context, name string, missing checkStatus, bin string, args ...string) checkResult {
	path, err := exec.LookPath(bin)
	if err != nil {
		return checkResult{name, missing, "未在 PATH 中找到 " + bin}
	}
	out, err := exec.CommandContext(ctx, path, args...).Output()
	if err != nil {
		return checkResult{name, missing, fmt.Sprintf("%s 运行失败：%v", path, err)}
	}
	return checkResult{name, statusOK, firstLine(string(out))}
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return s[:i]
	}
	return s
}

type vsInstance struct {
	InstallationPath    string `json:"installationPath"`
	InstallationVersion string `json:"installationVersion"`
	DisplayName         string `json:"displayName"`
}

func vswherePath() string {
	return filepath.Join(os.Getenv("ProgramFiles(x86)"), "Microsoft Visual Studio", "Installer", "vswhere.exe")
}

// findVS2019 mirrors tools/build-bm-bridge.ps1: VS 16.x with the x64 C++ tools.
func findVS2019(ctx context.Context) (vsInstance, error) {
	vswhere := vswherePath()
	if _, err := os.Stat(vswhere); err != nil {
		return vsInstance{}, fmt.Errorf("找不到 vswhere：%s", vswhere)
	}
	out, err := exec.CommandContext(ctx, vswhere, "-all", "-products", "*", "-version", "[16.0,17.0)",
		"-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-format", "json", "-utf8").Output()
	if err != nil {
		return vsInstance{}, fmt.Errorf("vswhere 运行失败：%w", err)
	}
	inst, err := pickVSInstance(out)
	if err != nil {
		return vsInstance{}, err
	}
	return inst, nil
}

func pickVSInstance(jsonOut []byte) (vsInstance, error) {
	var list []vsInstance
	if err := json.Unmarshal(jsonOut, &list); err != nil {
		return vsInstance{}, fmt.Errorf("无法解析 vswhere 输出：%w", err)
	}
	if len(list) == 0 || strings.TrimSpace(list[0].InstallationPath) == "" {
		return vsInstance{}, errors.New("未找到带 x64 C++ 工具的 VS 2019（16.x）；build-bm-bridge.ps1 只接受该版本")
	}
	return list[0], nil
}

func vcvars64(inst vsInstance) string {
	return filepath.Join(inst.InstallationPath, "VC", "Auxiliary", "Build", "vcvars64.bat")
}

func checkVisualStudio(ctx context.Context) []checkResult {
	inst, err := findVS2019(ctx)
	if err != nil {
		return []checkResult{{"Visual Studio 2019", statusFail, err.Error()}}
	}
	res := []checkResult{{"Visual Studio 2019", statusOK,
		fmt.Sprintf("%s %s（%s）", inst.DisplayName, inst.InstallationVersion, inst.InstallationPath)}}
	vcvars := vcvars64(inst)
	if _, err := os.Stat(vcvars); err != nil {
		return append(res, checkResult{"vcvars64.bat", statusFail, "缺少 " + vcvars})
	}
	res = append(res, checkResult{"vcvars64.bat", statusOK, vcvars})
	out, err := cmdLine(ctx, fmt.Sprintf(`call "%s" >nul && where cl.exe && where link.exe`, vcvars)).Output()
	cl, link := parseWhereTools(string(out))
	if err != nil || cl == "" || link == "" {
		return append(res, checkResult{"MSVC cl/link", statusFail,
			fmt.Sprintf("vcvars64 环境中未找到 cl.exe/link.exe（err=%v）", err)})
	}
	return append(res, checkResult{"MSVC cl/link", statusOK, cl + "；" + link})
}

// parseWhereTools picks the first cl.exe and link.exe paths from `where` output.
func parseWhereTools(out string) (cl, link string) {
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		switch strings.ToLower(filepath.Base(l)) {
		case "cl.exe":
			if cl == "" {
				cl = l
			}
		case "link.exe":
			if link == "" {
				link = l
			}
		}
	}
	return cl, link
}

func findCMake() (string, error) {
	if p, err := exec.LookPath("cmake"); err == nil {
		return p, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if inst, err := findVS2019(ctx); err == nil {
		p := filepath.Join(inst.InstallationPath, "Common7", "IDE", "CommonExtensions", "Microsoft", "CMake", "CMake", "bin", "cmake.exe")
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	return "", errors.New("PATH 与 VS 2019 安装目录中都没有 cmake.exe")
}

func checkCMake(ctx context.Context) checkResult {
	p, err := findCMake()
	if err != nil {
		return checkResult{"CMake（可选）", statusWarn, err.Error() + "；仅 `wirex build --cmake` 需要"}
	}
	out, err := exec.CommandContext(ctx, p, "--version").Output()
	if err != nil {
		return checkResult{"CMake（可选）", statusWarn, fmt.Sprintf("%s 运行失败：%v", p, err)}
	}
	return checkResult{"CMake（可选）", statusOK, firstLine(string(out)) + "（" + p + "）"}
}

func checkWindowsPowerShell(ctx context.Context) checkResult {
	out, err := powershellEncoded(ctx, "", "$PSVersionTable.PSVersion.ToString()").Output()
	if err != nil {
		return checkResult{"Windows PowerShell", statusFail, fmt.Sprintf("powershell.exe 运行失败：%v", err)}
	}
	return judgePowerShellVersion(firstLine(string(out)))
}

func judgePowerShellVersion(v string) checkResult {
	if strings.HasPrefix(v, "5.1.") || v == "5.1" {
		return checkResult{"Windows PowerShell", statusOK, v}
	}
	return checkResult{"Windows PowerShell", statusFail, fmt.Sprintf("需要 5.1，实际 %q", v)}
}

// parseSerialComm extracts COM names from `reg query HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`.
func parseSerialComm(out string) []string {
	var ports []string
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) >= 3 && f[len(f)-2] == "REG_SZ" {
			ports = append(ports, f[len(f)-1])
		}
	}
	sort.Strings(ports)
	return ports
}

func checkSerialPorts(ctx context.Context) checkResult {
	out, err := exec.CommandContext(ctx, "reg", "query", `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`).Output()
	if err != nil {
		// The key is absent when no serial device has ever been enumerated.
		return checkResult{"COM 串口", statusWarn, "SERIALCOMM 注册表项不存在或不可读，未发现串口"}
	}
	ports := parseSerialComm(string(out))
	if len(ports) == 0 {
		return checkResult{"COM 串口", statusWarn, "未发现串口"}
	}
	return checkResult{"COM 串口", statusOK, strings.Join(ports, ", ")}
}

// countActiveEndpoints counts DEVICE_STATE_ACTIVE (low bits == 1) entries in
// `reg query ...\MMDevices\Audio\<flow> /s /v DeviceState` output.
func countActiveEndpoints(out string) int {
	n := 0
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) == 3 && f[0] == "DeviceState" && f[1] == "REG_DWORD" {
			var v uint32
			if _, err := fmt.Sscanf(f[2], "0x%x", &v); err == nil && v&0xF == 1 {
				n++
			}
		}
	}
	return n
}

func checkAudioEndpoints(ctx context.Context) checkResult {
	counts := map[string]int{}
	for _, flow := range []string{"Render", "Capture"} {
		key := `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\` + flow
		out, err := exec.CommandContext(ctx, "reg", "query", key, "/s", "/v", "DeviceState").Output()
		if err != nil {
			return checkResult{"音频终结点", statusWarn, fmt.Sprintf("无法读取 %s：%v", key, err)}
		}
		counts[flow] = countActiveEndpoints(string(out))
	}
	detail := fmt.Sprintf("活动播放 %d 个，活动录音 %d 个", counts["Render"], counts["Capture"])
	if counts["Render"] == 0 || counts["Capture"] == 0 {
		return checkResult{"音频终结点", statusWarn, detail}
	}
	return checkResult{"音频终结点", statusOK, detail}
}

func checkGitClean(root string) checkResult {
	out, err := gitOutput(root, "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return checkResult{"Git 工作树", statusFail, err.Error()}
	}
	if out != "" {
		n := len(strings.Split(out, "\n"))
		return checkResult{"Git 工作树", statusWarn, fmt.Sprintf("%d 项未提交改动；构建会标记 -dirty，打包会拒绝", n)}
	}
	return checkResult{"Git 工作树", statusOK, "干净（" + root + "）"}
}

// fixturePath returns private/fixtures/device-y.bin of this checkout, falling back
// to the main checkout (read in place by absolute path) when run from a worktree.
func fixturePath(root string) string {
	p := filepath.Join(root, "private", "fixtures", "device-y.bin")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	common, err := gitOutput(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return p
	}
	mainCheckout := filepath.Join(filepath.Dir(filepath.Clean(common)), "private", "fixtures", "device-y.bin")
	if _, err := os.Stat(mainCheckout); err == nil {
		return mainCheckout
	}
	return p
}

func checkFixture(root string) checkResult {
	p := fixturePath(root)
	sum, err := fileSha256(p)
	if err != nil {
		return checkResult{"HRI 模板 fixture", statusWarn, "缺少 " + p + "；打包与部分离线测试需要"}
	}
	if !strings.EqualFold(filepath.Dir(filepath.Dir(filepath.Dir(p))), filepath.Clean(root)) {
		return checkResult{"HRI 模板 fixture", statusWarn, "当前 checkout 无 private/fixtures；打包会使用 " + p +
			"，但写死仓库内路径的 ps1 测试会失败"}
	}
	if sum != approvedFixtureSha256 {
		return checkResult{"HRI 模板 fixture", statusWarn, "SHA-256 与获批文件不符：" + sum}
	}
	return checkResult{"HRI 模板 fixture", statusOK, p}
}

func fileSha256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// ---------------------------------------------------------------- build

type buildOptions struct {
	Debug        bool
	CompileOnly  bool
	CMake        bool
	WithLauncher bool
}

func parseBuildArgs(args []string) (buildOptions, error) {
	fs := newFlagSet("build")
	release := fs.Bool("release", false, "")
	debug := fs.Bool("debug", false, "")
	compileOnly := fs.Bool("compile-only", false, "")
	useCMake := fs.Bool("cmake", false, "")
	withLauncher := fs.Bool("with-launcher", false, "")
	if err := parseFlags(fs, args); err != nil {
		return buildOptions{}, err
	}
	if *release && *debug {
		return buildOptions{}, usageError{"--release 与 --debug 不能同时使用"}
	}
	if *debug && !*useCMake {
		return buildOptions{}, usageError{"tools/build-bm-bridge.ps1 固定为 Release（/O2 /MT）；Debug 构建请加 --cmake"}
	}
	return buildOptions{Debug: *debug, CompileOnly: *compileOnly, CMake: *useCMake, WithLauncher: *withLauncher}, nil
}

func cmdBuild(args []string) error {
	opts, err := parseBuildArgs(args)
	if err != nil {
		return err
	}
	root, err := repoRoot()
	if err != nil {
		return err
	}
	if opts.CMake {
		return buildCMake(root, opts)
	}
	dir, logPath, err := buildNative(root, opts.CompileOnly)
	if err != nil {
		return err
	}
	fmt.Println("\n== 产物")
	fmt.Println("构建目录：", dir)
	fmt.Println("wirex_bridge：", filepath.Join(dir, "wirex_bridge.exe"))
	fmt.Println("wirex_probe：", filepath.Join(dir, "wirex_probe.exe"))
	fmt.Println("provenance：", filepath.Join(dir, "build-provenance.json"))
	fmt.Println("构建日志：", logPath)
	if opts.WithLauncher {
		launcher, err := buildLauncher(root)
		if err != nil {
			return err
		}
		fmt.Println("Launcher：", launcher)
	}
	return nil
}

var buildOutputLine = regexp.MustCompile(`(?m)^构建产物：(.+?)\s*$`)

// parseBuildOutputDir returns the directory from the script's "构建产物：" line.
func parseBuildOutputDir(log string) (string, error) {
	m := buildOutputLine.FindAllStringSubmatch(log, -1)
	if len(m) == 0 {
		return "", errors.New("构建输出中缺少“构建产物：”行")
	}
	return strings.TrimSpace(m[len(m)-1][1]), nil
}

// buildNative runs tools/build-bm-bridge.ps1 and tees its output to a UTF-8 log
// under build/_work (the location and encoding package-release.ps1 expects).
// On success the log is renamed to <build-dir>.log next to the build directory.
func buildNative(root string, compileOnly bool) (dir, logPath string, err error) {
	if err := os.MkdirAll(workRoot(root), 0o755); err != nil {
		return "", "", fmt.Errorf("创建 build/_work 失败：%w", err)
	}
	logPath = filepath.Join(workRoot(root), "wirex-build-"+time.Now().UTC().Format("20060102-150405")+".log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return "", "", fmt.Errorf("创建构建日志失败：%w", err)
	}
	var captured strings.Builder
	var scriptArgs []string
	if compileOnly {
		scriptArgs = append(scriptArgs, "-CompileOnly")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
	defer cancel()
	fmt.Println("运行 tools/build-bm-bridge.ps1", strings.Join(scriptArgs, " "))
	cmd := powershellFile(ctx, root, false, filepath.Join(root, "tools", "build-bm-bridge.ps1"), scriptArgs...)
	code, runErr := runStreaming(ctx, cmd, consoleCodePage(), os.Stdout, logFile, &captured)
	if cerr := logFile.Close(); cerr != nil && runErr == nil {
		runErr = fmt.Errorf("关闭构建日志失败：%w", cerr)
	}
	if runErr != nil {
		return "", logPath, runErr
	}
	if code != 0 {
		return "", logPath, fmt.Errorf("build-bm-bridge.ps1 失败（退出码 %d），日志：%s", code, logPath)
	}
	dir, err = parseBuildOutputDir(captured.String())
	if err != nil {
		return "", logPath, err
	}
	finalLog := dir + ".log"
	if err := os.Rename(logPath, finalLog); err != nil {
		return dir, logPath, fmt.Errorf("构建成功，但重命名日志失败（日志仍在 %s）：%w", logPath, err)
	}
	return dir, finalLog, nil
}

func buildLauncher(root string) (string, error) {
	head, err := gitHead(root)
	if err != nil {
		return "", err
	}
	out := filepath.Join(workRoot(root), fmt.Sprintf("wirex-launcher-%s-%s", head[:7], time.Now().UTC().Format("20060102-150405")))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	fmt.Println("运行 tools/build-launcher.ps1 →", out)
	cmd := powershellFile(ctx, root, false, filepath.Join(root, "tools", "build-launcher.ps1"),
		"-SourceCommit", head, "-OutputDirectory", out)
	code, err := runStreaming(ctx, cmd, consoleCodePage(), os.Stdout)
	if err != nil {
		return "", err
	}
	if code != 0 {
		return "", fmt.Errorf("build-launcher.ps1 失败（退出码 %d）", code)
	}
	return filepath.Join(out, "WirexBridge.exe"), nil
}

// buildCMake configures CMakeLists.txt with the VS 2019 generator. It produces no
// provenance, so its output is for development only and cannot be packaged.
func buildCMake(root string, opts buildOptions) error {
	cmakeExe, err := findCMake()
	if err != nil {
		return fmt.Errorf("--cmake 不可用：%w", err)
	}
	config := "Release"
	if opts.Debug {
		config = "Debug"
	}
	buildDir := filepath.Join(root, "build", "cmake-vs2019")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
	defer cancel()
	steps := [][]string{
		{cmakeExe, "-S", root, "-B", buildDir, "-G", "Visual Studio 16 2019", "-A", "x64"},
		{cmakeExe, "--build", buildDir, "--config", config, "--parallel"},
	}
	if !opts.CompileOnly {
		ctest := filepath.Join(filepath.Dir(cmakeExe), "ctest.exe")
		steps = append(steps, []string{ctest, "--test-dir", buildDir, "-C", config, "--output-on-failure"})
	}
	for _, s := range steps {
		fmt.Println(">", strings.Join(s, " "))
		cmd := exec.CommandContext(ctx, s[0], s[1:]...)
		cmd.Dir = root
		code, err := runStreaming(ctx, cmd, consoleCodePage(), os.Stdout)
		if err != nil {
			return err
		}
		if code != 0 {
			return fmt.Errorf("%s 失败（退出码 %d）", filepath.Base(s[0]), code)
		}
	}
	fmt.Println("\n== 产物（CMake，无 provenance，不能用于打包）")
	fmt.Println("wirex_bridge：", filepath.Join(buildDir, config, "wirex_bridge.exe"))
	return nil
}

// ---------------------------------------------------------------- build discovery

type nativeProvenance struct {
	SourceCommit    string `json:"source_commit"`
	SourceTreeClean bool   `json:"source_tree_clean"`
	CompileOnly     bool   `json:"compile_only"`
	Result          string `json:"result"`
}

var buildDirName = regexp.MustCompile(`^wirex-bridge-[0-9a-f]{7}(-dirty)?-(\d{8}-\d{6})$`)

// sortBuildDirs orders build/_work/wirex-bridge-* names newest first by their
// embedded UTC timestamp; non-matching names are dropped.
func sortBuildDirs(names []string) []string {
	var out []string
	for _, n := range names {
		if buildDirName.MatchString(n) {
			out = append(out, n)
		}
	}
	stamp := func(n string) string { return buildDirName.FindStringSubmatch(n)[2] }
	sort.SliceStable(out, func(i, j int) bool { return stamp(out[i]) > stamp(out[j]) })
	return out
}

func readProvenance(dir string) (nativeProvenance, error) {
	var p nativeProvenance
	b, err := os.ReadFile(filepath.Join(dir, "build-provenance.json"))
	if err != nil {
		return p, err
	}
	b = []byte(strings.TrimPrefix(string(b), "\ufeff"))
	if err := json.Unmarshal(b, &p); err != nil {
		return p, fmt.Errorf("无法解析 %s/build-provenance.json：%w", dir, err)
	}
	return p, nil
}

// findNativeBuild returns the newest build directory whose provenance satisfies keep.
func findNativeBuild(root string, keep func(nativeProvenance) bool) (string, nativeProvenance, error) {
	entries, err := os.ReadDir(workRoot(root))
	if err != nil {
		return "", nativeProvenance{}, fmt.Errorf("读取 build/_work 失败：%w", err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	for _, n := range sortBuildDirs(names) {
		dir := filepath.Join(workRoot(root), n)
		if p, err := readProvenance(dir); err == nil && keep(p) {
			return dir, p, nil
		}
	}
	return "", nativeProvenance{}, errors.New("build/_work 下没有符合条件的 Native 构建")
}

type launcherProvenance struct {
	Source struct {
		Commit string `json:"commit"`
	} `json:"source"`
}

// findLauncherBuild returns the newest build/_work/* directory holding a launcher
// build whose source commit matches (or any commit when commit is empty).
func findLauncherBuild(root, commit string) (string, string, error) {
	entries, err := os.ReadDir(workRoot(root))
	if err != nil {
		return "", "", fmt.Errorf("读取 build/_work 失败：%w", err)
	}
	type cand struct {
		dir, commit string
		mod         time.Time
	}
	var cands []cand
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(workRoot(root), e.Name())
		b, err := os.ReadFile(filepath.Join(dir, "launcher-build-provenance.json"))
		if err != nil {
			continue
		}
		var p launcherProvenance
		if json.Unmarshal([]byte(strings.TrimPrefix(string(b), "\ufeff")), &p) != nil {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, "WirexBridge.exe")); err != nil {
			continue
		}
		if commit != "" && p.Source.Commit != commit {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		cands = append(cands, cand{dir, p.Source.Commit, info.ModTime()})
	}
	if len(cands) == 0 {
		return "", "", errors.New("build/_work 下没有可用的 launcher 构建（可运行 wirex build --with-launcher）")
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].mod.After(cands[j].mod) })
	return cands[0].dir, cands[0].commit, nil
}

// ---------------------------------------------------------------- test

// psTest describes one PowerShell offline test under tools/. Keep this list in
// sync with the scripts that remain in the repository.
type psTest struct {
	Name          string // file name without .ps1
	STA           bool   // WPF tests require a single-threaded apartment
	NeedsLauncher bool   // passes -LauncherPath <WirexBridge.exe>
}

var psOfflineTests = []psTest{
	{Name: "test-package-release"},
	{Name: "test-publish-release"},
	{Name: "test-download-release"},
	{Name: "test-r126-zip-only"},
	{Name: "test-launcher", NeedsLauncher: true},
	{Name: "test-portable-config"},
	{Name: "test-ui-localization", STA: true},
	{Name: "test-ui-render", STA: true},
	{Name: "test-ui-channels", STA: true},
	{Name: "test-ui-console", STA: true},
	{Name: "test-ui-status", STA: true},
	{Name: "test-channel-activation-state"},
}

type testStatus int

const (
	testPass testStatus = iota
	testFail
	testSkip
)

func (s testStatus) String() string { return [...]string{"PASS", "FAIL", "SKIP"}[s] }

type testResult struct {
	Suite    string
	Name     string
	Status   testStatus
	Detail   string
	Duration time.Duration
}

type testSummary struct{ Pass, Fail, Skip int }

func summarize(results []testResult) testSummary {
	var s testSummary
	for _, r := range results {
		switch r.Status {
		case testPass:
			s.Pass++
		case testFail:
			s.Fail++
		case testSkip:
			s.Skip++
		}
	}
	return s
}

// classifyExit maps a test process exit code; 77 is CTest's SKIP_RETURN_CODE
// (used by console_lifecycle_test).
func classifyExit(code int) testStatus {
	switch code {
	case 0:
		return testPass
	case 77:
		return testSkip
	default:
		return testFail
	}
}

type testOptions struct {
	All      bool
	BuildDir string
	Launcher string
	Filter   string
}

func parseTestArgs(args []string) (testOptions, error) {
	fs := newFlagSet("test")
	offline := fs.Bool("offline", false, "")
	all := fs.Bool("all", false, "")
	var o testOptions
	fs.StringVar(&o.BuildDir, "build-dir", "", "")
	fs.StringVar(&o.Launcher, "launcher", "", "")
	fs.StringVar(&o.Filter, "run", "", "")
	if err := parseFlags(fs, args); err != nil {
		return o, err
	}
	if *offline && *all {
		return o, usageError{"--offline 与 --all 不能同时使用"}
	}
	if *all && (o.BuildDir != "" || o.Launcher != "") {
		return o, usageError{"--all 会重新构建，不能与 --build-dir/--launcher 同用"}
	}
	o.All = *all
	return o, nil
}

var testSpecName = regexp.MustCompile(`@\{\s*Name='([A-Za-z0-9_]+)';\s*Source='tests\\`)

// parseNativeTestNames reads the ordered test list from build-bm-bridge.ps1 so the
// script stays the single source of truth for the release test profile.
func parseNativeTestNames(script string) []string {
	var names []string
	for _, m := range testSpecName.FindAllStringSubmatch(script, -1) {
		names = append(names, m[1])
	}
	return names
}

func matchesFilter(name, filter string) bool {
	return filter == "" || strings.Contains(name, filter)
}

func cmdTest(args []string) error {
	opts, err := parseTestArgs(args)
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

	buildDir, launcher := opts.BuildDir, opts.Launcher
	if opts.All {
		fmt.Println("== --all：完整构建（含脚本内 Native 测试）与 launcher 构建")
		if buildDir, _, err = buildNative(root, false); err != nil {
			return err
		}
		if launcher, err = buildLauncher(root); err != nil {
			return err
		}
	}

	var results []testResult
	nativeResults, err := runNativeTests(root, head, buildDir, opts.Filter)
	if err != nil {
		return err
	}
	results = append(results, nativeResults...)
	results = append(results, runPSTests(root, head, launcher, opts.Filter)...)

	fmt.Println("\n== 汇总")
	for _, r := range results {
		fmt.Printf("[%s] %-7s %-34s %6.1fs %s\n", r.Status, r.Suite, r.Name, r.Duration.Seconds(), r.Detail)
	}
	s := summarize(results)
	fmt.Printf("通过 %d，失败 %d，跳过 %d\n", s.Pass, s.Fail, s.Skip)
	if s.Fail > 0 {
		return fmt.Errorf("%d 项测试失败", s.Fail)
	}
	return nil
}

func runNativeTests(root, head, buildDir, filter string) ([]testResult, error) {
	script, err := os.ReadFile(filepath.Join(root, "tools", "build-bm-bridge.ps1"))
	if err != nil {
		return nil, fmt.Errorf("读取 build-bm-bridge.ps1 失败：%w", err)
	}
	names := parseNativeTestNames(string(script))
	if len(names) == 0 {
		return nil, errors.New("未能从 build-bm-bridge.ps1 解析出 Native 测试清单")
	}
	if buildDir == "" {
		buildDir, _, err = findNativeBuild(root, func(p nativeProvenance) bool {
			return !p.CompileOnly && p.Result == "passed" && p.SourceCommit == head
		})
		if err != nil {
			return nil, fmt.Errorf("没有当前 HEAD（%s）的完整 Native 构建；先运行 `wirex build`，或用 --build-dir 指定：%w", head[:7], err)
		}
	}
	if p, err := readProvenance(buildDir); err == nil && p.SourceCommit != head {
		fmt.Printf("WARN：构建目录来自提交 %s，不是当前 HEAD %s\n", p.SourceCommit, head)
	}
	fmt.Printf("== Native 测试（%d 项，来自 %s）\n", len(names), buildDir)
	var results []testResult
	for _, name := range names {
		if !matchesFilter(name, filter) {
			continue
		}
		exe := filepath.Join(buildDir, name+".exe")
		if _, err := os.Stat(exe); err != nil {
			results = append(results, testResult{"native", name, testFail, "缺少测试程序（--compile-only 构建不链接测试）", 0})
			continue
		}
		results = append(results, runOneTest("native", name, root, 10*time.Minute, cpUTF8,
			func(ctx context.Context) *exec.Cmd {
				cmd := exec.CommandContext(ctx, exe)
				cmd.Dir = root // build-bm-bridge.ps1 runs tests from the repository root
				return cmd
			}))
	}
	return results, nil
}

func runPSTests(root, head, launcher, filter string) []testResult {
	var results []testResult
	for _, t := range psOfflineTests {
		if !matchesFilter(t.Name, filter) {
			continue
		}
		script := filepath.Join(root, "tools", t.Name+".ps1")
		if _, err := os.Stat(script); err != nil {
			fmt.Printf("WARN：%s 不存在，跳过\n", script)
			results = append(results, testResult{"pwsh5", t.Name, testSkip, "脚本不存在", 0})
			continue
		}
		var args []string
		if t.NeedsLauncher {
			exe := launcher
			if exe == "" {
				dir, commit, err := findLauncherBuild(root, "")
				if err != nil {
					fmt.Println("WARN：", err)
					results = append(results, testResult{"pwsh5", t.Name, testSkip, "没有 launcher 构建", 0})
					continue
				}
				if commit != head {
					fmt.Printf("WARN：launcher 构建来自提交 %.7s，不是当前 HEAD\n", commit)
				}
				exe = filepath.Join(dir, "WirexBridge.exe")
			}
			args = []string{"-LauncherPath", exe}
		}
		results = append(results, runOneTest("pwsh5", t.Name, root, 30*time.Minute, consoleCodePage(),
			func(ctx context.Context) *exec.Cmd { return powershellFile(ctx, root, t.STA, script, args...) }))
	}
	return results
}

func runOneTest(suite, name, root string, timeout time.Duration, cp uint32, mk func(context.Context) *exec.Cmd) testResult {
	fmt.Printf("\n--- %s %s\n", suite, name)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	start := time.Now()
	code, err := runStreaming(ctx, mk(ctx), cp, os.Stdout)
	r := testResult{Suite: suite, Name: name, Duration: time.Since(start)}
	switch {
	case err != nil:
		r.Status, r.Detail = testFail, err.Error()
	default:
		r.Status = classifyExit(code)
		if code != 0 {
			r.Detail = fmt.Sprintf("退出码 %d", code)
		}
	}
	return r
}

// ---------------------------------------------------------------- package

type packageOptions struct {
	Version     string
	BuildDir    string
	BuildLog    string
	LauncherDir string
	Fixture     string
	NativeRepo  string
	Zip         bool
	PackageRoot string
}

func parsePackageArgs(args []string) (packageOptions, error) {
	fs := newFlagSet("package")
	var o packageOptions
	fs.StringVar(&o.Version, "version", "", "")
	fs.StringVar(&o.BuildDir, "build-dir", "", "")
	fs.StringVar(&o.BuildLog, "build-log", "", "")
	fs.StringVar(&o.LauncherDir, "launcher-dir", "", "")
	fs.StringVar(&o.Fixture, "fixture", "", "")
	fs.StringVar(&o.NativeRepo, "native-repo", "", "")
	fs.BoolVar(&o.Zip, "zip", false, "")
	fs.StringVar(&o.PackageRoot, "package-root", "", "")
	if err := parseFlags(fs, args); err != nil {
		return o, err
	}
	if !regexp.MustCompile(`^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$`).MatchString(o.Version) {
		return o, usageError{fmt.Sprintf("--version 必须形如 v0.1.1 或 v0.1.1-test.2，实际 %q", o.Version)}
	}
	if o.Zip && (o.BuildDir != "" || o.BuildLog != "" || o.LauncherDir != "" || o.Fixture != "" || o.NativeRepo != "") {
		return o, usageError{"--zip 只从已有包目录生成 ZIP，不接受构建相关参数"}
	}
	if !o.Zip && o.PackageRoot != "" {
		return o, usageError{"--package-root 仅用于 --zip"}
	}
	return o, nil
}

func cmdPackage(args []string) error {
	opts, err := parsePackageArgs(args)
	if err != nil {
		return err
	}
	root, err := repoRoot()
	if err != nil {
		return err
	}
	if opts.Zip {
		return packageZip(root, opts)
	}
	head, err := gitHead(root)
	if err != nil {
		return err
	}
	nativeRepo := root
	if opts.NativeRepo != "" {
		nativeRepo = opts.NativeRepo
	}
	if opts.BuildDir == "" {
		opts.BuildDir, _, err = findNativeBuild(nativeRepo, func(p nativeProvenance) bool {
			return !p.CompileOnly && p.Result == "passed" && p.SourceTreeClean
		})
		if err != nil {
			return fmt.Errorf("未找到干净的完整 Native 构建，请先在干净工作树运行 `wirex build` 或指定 --build-dir：%w", err)
		}
	}
	if opts.BuildLog == "" {
		opts.BuildLog = filepath.Clean(opts.BuildDir) + ".log"
		if _, err := os.Stat(opts.BuildLog); err != nil {
			return fmt.Errorf("找不到构建日志 %s（wirex build 会生成该文件），请用 --build-log 指定", opts.BuildLog)
		}
	}
	if opts.LauncherDir == "" {
		if dir, _, err := findLauncherBuild(root, head); err == nil {
			opts.LauncherDir = dir
		} else {
			fmt.Println("WARN：未找到当前 HEAD 的 launcher 构建；alpha 版本可不需要，v0.1.0/ZIP-only 版本需要（wirex build --with-launcher）")
		}
	}
	if opts.Fixture == "" {
		opts.Fixture = fixturePath(root)
	}

	scriptArgs := []string{"-Version", opts.Version, "-BuildDirectory", opts.BuildDir, "-BuildLogPath", opts.BuildLog,
		"-YFixturePath", opts.Fixture}
	if opts.LauncherDir != "" {
		scriptArgs = append(scriptArgs, "-LauncherBuildDirectory", opts.LauncherDir)
	}
	if opts.NativeRepo != "" {
		scriptArgs = append(scriptArgs, "-NativeBuildRepositoryRoot", opts.NativeRepo)
	}
	fmt.Println("运行 tools/package-release.ps1", strings.Join(scriptArgs, " "))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	cmd := powershellFile(ctx, root, false, filepath.Join(root, "tools", "package-release.ps1"), scriptArgs...)
	code, err := runStreaming(ctx, cmd, consoleCodePage(), os.Stdout)
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("package-release.ps1 失败（退出码 %d）", code)
	}
	fmt.Println("\n== 产物")
	fmt.Println("包目录：", filepath.Join(root, "build", "releases", opts.Version))
	return nil
}

func packageZip(root string, opts packageOptions) error {
	pkg := opts.PackageRoot
	if pkg == "" {
		pkg = filepath.Join(root, "build", "releases", opts.Version)
	}
	if _, err := os.Stat(pkg); err != nil {
		return fmt.Errorf("包目录不存在：%s（先运行 wirex package --version %s）", pkg, opts.Version)
	}
	script := strings.Join([]string{
		"$ErrorActionPreference = 'Stop'",
		"try {",
		"  . " + psQuote(filepath.Join(root, "tools", "package-release.ps1")),
		"  $r = New-ZipOnlyReleaseDistribution -PackageRoot " + psQuote(pkg) + " -RepositoryRoot " + psQuote(root) +
			" -Version " + psQuote(opts.Version),
		"  $r | Format-List | Out-String | Write-Host",
		"} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }",
		"exit 0",
	}, "\n")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	code, err := runStreaming(ctx, powershellEncoded(ctx, root, script), consoleCodePage(), os.Stdout)
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("ZIP 生成失败（退出码 %d）", code)
	}
	fmt.Println("\n== 产物")
	fmt.Println("ZIP 目录：", filepath.Join(root, "build", "_work", "r126-distribution", opts.Version))
	return nil
}
