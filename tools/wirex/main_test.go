//go:build windows

package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestParseBuildArgs(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		want    buildOptions
		wantErr bool
	}{
		{"default is script release build", nil, buildOptions{}, false},
		{"explicit release", []string{"--release"}, buildOptions{Release: true}, false},
		{"compile only", []string{"--compile-only"}, buildOptions{CompileOnly: true}, false},
		{"cmake debug", []string{"--cmake", "--debug"}, buildOptions{CMake: true, Debug: true}, false},
		{"with launcher", []string{"--with-launcher"}, buildOptions{WithLauncher: true}, false},
		{"gui only", []string{"--gui"}, buildOptions{GUI: true}, false},
		{"gui with explicit release", []string{"--gui", "--release"}, buildOptions{GUI: true, Release: true}, false},
		{"gui release with debug rejected", []string{"--gui", "--release", "--debug"}, buildOptions{}, true},
		{"gui with compile only rejected", []string{"--gui", "--compile-only"}, buildOptions{}, true},
		{"gui with cmake rejected", []string{"--gui", "--cmake"}, buildOptions{}, true},
		{"gui with launcher rejected", []string{"--gui", "--with-launcher"}, buildOptions{}, true},
		{"gui with debug rejected", []string{"--gui", "--debug", "--cmake"}, buildOptions{}, true},
		{"debug without cmake rejected", []string{"--debug"}, buildOptions{}, true},
		{"release and debug conflict", []string{"--release", "--debug", "--cmake"}, buildOptions{}, true},
		{"unknown flag", []string{"--fast"}, buildOptions{}, true},
		{"positional argument", []string{"extra"}, buildOptions{}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseBuildArgs(tt.args)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if err != nil {
				var ue usageError
				if !errors.As(err, &ue) {
					t.Fatalf("want usageError, got %T", err)
				}
				return
			}
			if got != tt.want {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestParseTestArgs(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		want    testOptions
		wantErr bool
	}{
		{"default offline", nil, testOptions{}, false},
		{"explicit offline", []string{"--offline"}, testOptions{}, false},
		{"all", []string{"--all"}, testOptions{All: true}, false},
		{"build dir and filter", []string{"--build-dir", `C:\b`, "--run", "ui"}, testOptions{BuildDir: `C:\b`, Filter: "ui"}, false},
		{"launcher path", []string{"--launcher", `C:\l.exe`}, testOptions{Launcher: `C:\l.exe`}, false},
		{"offline and all conflict", []string{"--offline", "--all"}, testOptions{}, true},
		{"all with build dir conflict", []string{"--all", "--build-dir", "x"}, testOptions{}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseTestArgs(tt.args)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if err == nil && got != tt.want {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestParsePackageArgs(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		want    packageOptions
		wantErr bool
	}{
		{"version only", []string{"--version", "v0.1.1"}, packageOptions{Version: "v0.1.1"}, false},
		{"prerelease version", []string{"--version", "v0.1.1-test.2"}, packageOptions{Version: "v0.1.1-test.2"}, false},
		{"explicit evidence", []string{"--version", "v0.1.0-alpha.13", "--build-dir", "b", "--build-log", "l", "--fixture", "f"},
			packageOptions{Version: "v0.1.0-alpha.13", BuildDir: "b", BuildLog: "l", Fixture: "f"}, false},
		{"zip with package root", []string{"--version", "v0.1.1", "--zip", "--package-root", "p"},
			packageOptions{Version: "v0.1.1", Zip: true, PackageRoot: "p"}, false},
		{"missing version", nil, packageOptions{}, true},
		{"version without v", []string{"--version", "0.1.1"}, packageOptions{}, true},
		{"zip rejects build dir", []string{"--version", "v0.1.1", "--zip", "--build-dir", "b"}, packageOptions{}, true},
		{"package root needs zip", []string{"--version", "v0.1.1", "--package-root", "p"}, packageOptions{}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parsePackageArgs(tt.args)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if err == nil && got != tt.want {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestRunDispatch(t *testing.T) {
	tests := []struct {
		name      string
		args      []string
		wantUsage bool
	}{
		{"no command", nil, true},
		{"unknown command", []string{"deploy"}, true},
		{"bad doctor flag", []string{"doctor", "--x"}, true},
		{"help", []string{"help"}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := run(tt.args)
			var ue usageError
			if got := errors.As(err, &ue); got != tt.wantUsage {
				t.Fatalf("usage error = %v (err=%v), want %v", got, err, tt.wantUsage)
			}
		})
	}
}

func TestDoctorFailures(t *testing.T) {
	tests := []struct {
		name    string
		results []checkResult
		want    int
	}{
		{"empty", nil, 0},
		{"all ok", []checkResult{{Status: statusOK}, {Status: statusOK}}, 0},
		{"warn is not failure", []checkResult{{Status: statusOK}, {Status: statusWarn}}, 0},
		{"one fail", []checkResult{{Status: statusWarn}, {Status: statusFail}}, 1},
		{"two fails", []checkResult{{Status: statusFail}, {Status: statusOK}, {Status: statusFail}}, 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := doctorFailures(tt.results); got != tt.want {
				t.Fatalf("got %d, want %d", got, tt.want)
			}
		})
	}
}

func TestJudgePowerShellVersion(t *testing.T) {
	tests := []struct {
		version string
		want    checkStatus
	}{
		{"5.1.26100.8737", statusOK},
		{"5.1", statusOK},
		{"7.6.0", statusFail},
		{"5.0.10586.117", statusFail},
		{"", statusFail},
	}
	for _, tt := range tests {
		t.Run(tt.version, func(t *testing.T) {
			if got := judgePowerShellVersion(tt.version).Status; got != tt.want {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
		})
	}
}

func TestParseSerialComm(t *testing.T) {
	tests := []struct {
		name string
		out  string
		want []string
	}{
		{"typical", "\r\nHKEY_LOCAL_MACHINE\\HARDWARE\\DEVICEMAP\\SERIALCOMM\r\n" +
			"    \\Device\\Silabser0    REG_SZ    COM11\r\n    \\Device\\USBSER000    REG_SZ    COM5\r\n",
			[]string{"COM11", "COM5"}},
		{"key only", "HKEY_LOCAL_MACHINE\\HARDWARE\\DEVICEMAP\\SERIALCOMM\r\n", nil},
		{"ignores other types", "    \\Device\\X    REG_DWORD    0x1\r\n    \\Device\\Serial0    REG_SZ    COM1\r\n", []string{"COM1"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := parseSerialComm(tt.out); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
		})
	}
}

func TestCountActiveEndpoints(t *testing.T) {
	tests := []struct {
		name string
		out  string
		want int
	}{
		{"none", "", 0},
		{"active and unplugged", "    DeviceState    REG_DWORD    0x1\r\n    DeviceState    REG_DWORD    0x4\r\n" +
			"    DeviceState    REG_DWORD    0x10000001\r\n    DeviceState    REG_DWORD    0x20000004\r\n", 2},
		{"disabled only", "    DeviceState    REG_DWORD    0x2\r\n", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := countActiveEndpoints(tt.out); got != tt.want {
				t.Fatalf("got %d, want %d", got, tt.want)
			}
		})
	}
}

func TestParseWhereTools(t *testing.T) {
	out := "C:\\VS\\bin\\Hostx64\\x64\\cl.exe\r\nC:\\VS\\bin\\Hostx64\\x64\\link.exe\r\nC:\\Git\\usr\\bin\\link.exe\r\n"
	cl, link := parseWhereTools(out)
	if cl != `C:\VS\bin\Hostx64\x64\cl.exe` || link != `C:\VS\bin\Hostx64\x64\link.exe` {
		t.Fatalf("got cl=%q link=%q", cl, link)
	}
	if cl, link := parseWhereTools("INFO: Could not find files"); cl != "" || link != "" {
		t.Fatalf("expected empty, got %q %q", cl, link)
	}
}

func TestPickVSInstance(t *testing.T) {
	tests := []struct {
		name     string
		json     string
		wantPath string
		wantErr  bool
	}{
		{"one instance", `[{"installationPath":"C:\\VS\\2019\\BuildTools","installationVersion":"16.11.5"}]`, `C:\VS\2019\BuildTools`, false},
		{"empty list", `[]`, "", true},
		{"invalid json", `not json`, "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := pickVSInstance([]byte(tt.json))
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if got.InstallationPath != tt.wantPath {
				t.Fatalf("got %q, want %q", got.InstallationPath, tt.wantPath)
			}
		})
	}
}

func TestSummarizeAndClassify(t *testing.T) {
	codes := []struct {
		code int
		want testStatus
	}{{0, testPass}, {1, testFail}, {77, testSkip}, {-1, testFail}}
	for _, c := range codes {
		if got := classifyExit(c.code); got != c.want {
			t.Errorf("classifyExit(%d) = %v, want %v", c.code, got, c.want)
		}
	}

	tests := []struct {
		name    string
		results []testResult
		want    testSummary
	}{
		{"empty", nil, testSummary{}},
		{"mixed", []testResult{{Status: testPass}, {Status: testFail}, {Status: testSkip}, {Status: testPass}}, testSummary{2, 1, 1}},
		{"all pass", []testResult{{Status: testPass}, {Status: testPass}}, testSummary{Pass: 2}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := summarize(tt.results); got != tt.want {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestParseBuildOutputDir(t *testing.T) {
	tests := []struct {
		name    string
		log     string
		want    string
		wantErr bool
	}{
		{"found", "编译源码组：x\n构建产物：C:\\r\\build\\_work\\wirex-bridge-abc1234-20261104-010203\r\n可执行文件：y\n",
			`C:\r\build\_work\wirex-bridge-abc1234-20261104-010203`, false},
		{"last wins", "构建产物：A\n构建产物：B\n", "B", false},
		{"missing", "MSVC 命令失败\n", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseBuildOutputDir(tt.log)
			if (err != nil) != tt.wantErr || got != tt.want {
				t.Fatalf("got %q err=%v, want %q wantErr=%v", got, err, tt.want, tt.wantErr)
			}
		})
	}
}

func TestSortBuildDirs(t *testing.T) {
	in := []string{
		"wirex-bridge-aaaaaaa-20261101-000000",
		"other",
		"wirex-bridge-bbbbbbb-dirty-20261103-120000",
		"wirex-launcher-ccccccc-20261104-000000",
		"wirex-bridge-ccccccc-20261102-235959",
	}
	want := []string{
		"wirex-bridge-bbbbbbb-dirty-20261103-120000",
		"wirex-bridge-ccccccc-20261102-235959",
		"wirex-bridge-aaaaaaa-20261101-000000",
	}
	if got := sortBuildDirs(in); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseNativeTestNames(t *testing.T) {
	script := `$testSpecs = @(
        @{ Name='dmrd_test'; Source='tests\dmrd_test.cpp' },
        @{ Name='hri_p_status_test'; Source='tests\hri_p_status_test.cpp'; SupportSources=@('src\hri_p_status.cpp') },
        @{ Name='routing_state_test'; Source='tests\routing_state_test.cpp' }
    )`
	want := []string{"dmrd_test", "hri_p_status_test", "routing_state_test"}
	if got := parseNativeTestNames(script); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// TestNativeTestListMatchesRepository guards the regex against the real script:
// build-bm-bridge.ps1 and CMakeLists.txt both register the same 40 tests.
func TestNativeTestListMatchesRepository(t *testing.T) {
	root := filepath.Join("..", "..")
	script, err := os.ReadFile(filepath.Join(root, "tools", "build-bm-bridge.ps1"))
	if err != nil {
		t.Skip("build-bm-bridge.ps1 not found:", err)
	}
	cmake, err := os.ReadFile(filepath.Join(root, "CMakeLists.txt"))
	if err != nil {
		t.Skip("CMakeLists.txt not found:", err)
	}
	var cmakeNames []string
	for _, l := range strings.Split(string(cmake), "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "add_test(NAME ") {
			cmakeNames = append(cmakeNames, strings.Fields(l)[1])
		}
	}
	got := parseNativeTestNames(string(script))
	// Compare as sets: CMake registers bm_connection_config_test at a different
	// position; the release profile order is the script's.
	sorted := func(s []string) []string { c := append([]string(nil), s...); sort.Strings(c); return c }
	if len(got) < 40 || !reflect.DeepEqual(sorted(got), sorted(cmakeNames)) {
		t.Fatalf("script tests (%d) %v\n!= CMake tests (%d) %v", len(got), got, len(cmakeNames), cmakeNames)
	}
}

func TestMatchesFilter(t *testing.T) {
	tests := []struct {
		name, filter string
		want         bool
	}{
		{"dmrd_test", "", true},
		{"test-ui-render", "ui", true},
		{"dmrd_test", "ui", false},
	}
	for _, tt := range tests {
		if got := matchesFilter(tt.name, tt.filter); got != tt.want {
			t.Errorf("matchesFilter(%q,%q) = %v, want %v", tt.name, tt.filter, got, tt.want)
		}
	}
}

func TestWindowsPowerShellEnv(t *testing.T) {
	installer := filepath.Dir(vswherePath())
	tests := []struct {
		name string
		in   []string
		want []string
	}{
		{"drops PSModulePath and extends PATH",
			[]string{"Path=C:\\x", "PSModulePath=C:\\pwsh7", "Psmodulepath=y", "PSModulePathX=keep"},
			[]string{"Path=C:\\x;" + installer, "PSModulePathX=keep"}},
		{"PATH already has installer", []string{"PATH=" + installer}, []string{"PATH=" + installer}},
		{"PATHEXT untouched", []string{"PATHEXT=.EXE"}, []string{"PATHEXT=.EXE"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := windowsPowerShellEnv(tt.in); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
		})
	}
}

func TestPsQuote(t *testing.T) {
	if got := psQuote(`C:\it's dir`); got != `'C:\it''s dir'` {
		t.Fatalf("got %s", got)
	}
}

func TestDecodeCodePage(t *testing.T) {
	gbk := []byte{0xB9, 0xB9, 0xBD, 0xA8} // "构建" in CP936
	tests := []struct {
		name string
		cp   uint32
		in   []byte
		want string
	}{
		{"ascii passthrough", 936, []byte("ok"), "ok"},
		{"utf8 passthrough", cpUTF8, []byte("构建"), "构建"},
		{"gbk decode", 936, gbk, "构建"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := decodeCodePage(tt.cp, tt.in); got != tt.want {
				t.Fatalf("got %q, want %q", got, tt.want)
			}
		})
	}
}

// ---------------------------------------------------------------- package-gui

func testSha256(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeTestProvenance(t *testing.T, dir, commit string, dev, clean bool, exeSum string) {
	t.Helper()
	p := fmt.Sprintf(`{"schema_version":1,"dev_build":%t,"result":"passed",`+
		`"source":{"commit":%q,"tree_clean":%t},"imgui":{"version":"1.92.9b","path":"third_party/imgui"},`+
		`"compiler":{"family":"MSVC 2019"},"output":{"path":"WirexBridge.exe","length_bytes":8,"sha256":%q}}`,
		dev, commit, clean, exeSum)
	writeTestFile(t, filepath.Join(dir, guiProvenanceFile), p)
}

func TestParsePackageGUIArgs(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		want    packageGUIOptions
		wantErr bool
	}{
		{"version only", []string{"--version", "v0.2.0"}, packageGUIOptions{Version: "v0.2.0"}, false},
		{"all flags", []string{"--version", "v0.2.0", "--gui-dir", `C:\b`, "--notes", "n.md", "--allow-dirty"},
			packageGUIOptions{Version: "v0.2.0", GUIDir: `C:\b`, Notes: "n.md", AllowDirty: true}, false},
		{"prerelease version", []string{"--version", "v0.2.0-rc.1"}, packageGUIOptions{Version: "v0.2.0-rc.1"}, false},
		{"missing version", nil, packageGUIOptions{}, true},
		{"version without v", []string{"--version", "0.2.0"}, packageGUIOptions{}, true},
		{"unknown flag", []string{"--version", "v0.2.0", "--fast"}, packageGUIOptions{}, true},
		{"positional argument", []string{"--version", "v0.2.0", "extra"}, packageGUIOptions{}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parsePackageGUIArgs(tt.args)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if err == nil && got != tt.want {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestSortGUIBuildDirs(t *testing.T) {
	in := []string{
		"wirex-gui-aaaaaaa-20261101-000000",
		"other",
		"wirex-gui-bbbbbbb-dirty-20261103-120000",
		"wirex-gui-ccccccc-20261102-235959",
		"wirex-bridge-ddddddd-20261104-000000",
	}
	want := []string{
		"wirex-gui-bbbbbbb-dirty-20261103-120000",
		"wirex-gui-ccccccc-20261102-235959",
		"wirex-gui-aaaaaaa-20261101-000000",
	}
	if got := sortGUIBuildDirs(in); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestFindGUIBuild(t *testing.T) {
	const head = "b61bc455c0d9d035fd02a2d320f2caaf86ee9b41"
	const other = "7f4a395471c173d721ff15f52cf7949df25fa591"
	exeBody := "fake-exe"
	exeSum := testSha256([]byte(exeBody))
	makeBuild := func(root, name, commit string, dev, clean bool) string {
		dir := filepath.Join(workRoot(root), name)
		writeTestFile(t, filepath.Join(dir, "WirexBridge.exe"), exeBody)
		writeTestProvenance(t, dir, commit, dev, clean, exeSum)
		return dir
	}

	t.Run("skips dev and picks newest release", func(t *testing.T) {
		root := t.TempDir()
		makeBuild(root, "wirex-gui-bbbbbbb-20261103-120000", head, true, true)
		want := makeBuild(root, "wirex-gui-aaaaaaa-20261102-120000", head, false, true)
		got, prov, err := findGUIBuild(root, head, false)
		if err != nil {
			t.Fatal(err)
		}
		if got != want || prov.DevBuild {
			t.Fatalf("got %q dev=%v, want %q", got, prov.DevBuild, want)
		}
	})

	t.Run("skips commit mismatch", func(t *testing.T) {
		root := t.TempDir()
		makeBuild(root, "wirex-gui-bbbbbbb-20261103-120000", other, false, true)
		want := makeBuild(root, "wirex-gui-aaaaaaa-20261102-120000", head, false, true)
		got, _, err := findGUIBuild(root, head, false)
		if err != nil || got != want {
			t.Fatalf("got %q err=%v, want %q", got, err, want)
		}
	})

	t.Run("dirty requires allow-dirty", func(t *testing.T) {
		root := t.TempDir()
		dir := makeBuild(root, "wirex-gui-aaaaaaa-20261102-120000", head, false, false)
		if _, _, err := findGUIBuild(root, head, false); err == nil {
			t.Fatal("expected dirty build to be rejected")
		}
		got, _, err := findGUIBuild(root, head, true)
		if err != nil || got != dir {
			t.Fatalf("got %q err=%v, want %q", got, err, dir)
		}
	})

	t.Run("no builds", func(t *testing.T) {
		if _, _, err := findGUIBuild(t.TempDir(), head, false); err == nil {
			t.Fatal("expected error")
		}
	})
}

func TestValidateGUIBuild(t *testing.T) {
	const head = "b61bc455c0d9d035fd02a2d320f2caaf86ee9b41"
	const other = "7f4a395471c173d721ff15f52cf7949df25fa591"
	exeBody := "fake-exe"
	tests := []struct {
		name        string
		dev         bool
		clean       bool
		commitMatch bool
		allowDirty  bool
		badSum      bool
		wantErr     bool
	}{
		{"clean release", false, true, true, false, false, false},
		{"dirty release with allow-dirty", false, false, true, true, false, false},
		{"dirty release rejected", false, false, true, false, false, true},
		{"dev build rejected", true, true, true, false, false, true},
		{"commit mismatch rejected", false, true, false, false, false, true},
		{"commit mismatch not waived by allow-dirty", false, true, false, true, false, true},
		{"sha mismatch rejected", false, true, true, false, true, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			writeTestFile(t, filepath.Join(dir, "WirexBridge.exe"), exeBody)
			commit := head
			if !tt.commitMatch {
				commit = other
			}
			sum := testSha256([]byte(exeBody))
			if tt.badSum {
				sum = strings.Repeat("0", 64)
			}
			writeTestProvenance(t, dir, commit, tt.dev, tt.clean, sum)
			_, err := validateGUIBuild(dir, head, tt.allowDirty)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

type stageSetup struct {
	imguiNotice bool
	notes       bool
	license     bool
	exe         bool
}

func setupStageRepo(t *testing.T, s stageSetup) (repo, guiDir, notes string) {
	t.Helper()
	repo = t.TempDir()
	guiDir = filepath.Join(t.TempDir(), "wirex-gui-abc1234-20261107-000000")
	notes = filepath.Join(repo, "docs", "releases", "v0.2.0.md")
	if s.exe {
		writeTestFile(t, filepath.Join(guiDir, "WirexBridge.exe"), "fake-exe")
	}
	if s.notes {
		writeTestFile(t, notes, "# WIREX Bridge v0.2.0\n")
	}
	if s.license {
		for _, rel := range []string{
			"third_party/dmr_signal/COPYING.GPL-3.0.txt",
			"third_party/dmr_signal/NOTICE.md",
			"third_party/droidstar_mbe/COPYING.GPL-3.0.txt",
			"third_party/droidstar_mbe/ISC-NOTICE.txt",
			"third_party/imgui/LICENSE.txt",
		} {
			writeTestFile(t, filepath.Join(repo, filepath.FromSlash(rel)), "license:"+rel)
		}
		if s.imguiNotice {
			writeTestFile(t, filepath.Join(repo, "third_party", "imgui", "NOTICE.md"), "imgui notice")
		}
	}
	return repo, guiDir, notes
}

func TestStageGUIPackage(t *testing.T) {
	baseInventory := []string{
		"README.md",
		"WirexBridge.exe",
		"licenses/dmr_signal/COPYING.GPL-3.0.txt",
		"licenses/dmr_signal/NOTICE.md",
		"licenses/droidstar_mbe/COPYING.GPL-3.0.txt",
		"licenses/droidstar_mbe/ISC-NOTICE.txt",
		"licenses/imgui/LICENSE.txt",
	}
	withNotice := append(append([]string(nil), baseInventory...), "licenses/imgui/NOTICE.md")
	sort.Strings(baseInventory)
	sort.Strings(withNotice)

	tests := []struct {
		name    string
		setup   stageSetup
		stale   bool
		want    []string
		wantErr bool
	}{
		{"full inventory", stageSetup{imguiNotice: true, notes: true, license: true, exe: true}, false, withNotice, false},
		{"without optional imgui notice", stageSetup{notes: true, license: true, exe: true}, false, baseInventory, false},
		{"stale stage content removed", stageSetup{notes: true, license: true, exe: true}, true, baseInventory, false},
		{"missing notes", stageSetup{license: true, exe: true}, false, nil, true},
		{"missing license", stageSetup{notes: true, exe: true}, false, nil, true},
		{"missing exe", stageSetup{notes: true, license: true}, false, nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo, guiDir, notes := setupStageRepo(t, tt.setup)
			stage := filepath.Join(t.TempDir(), "stage")
			if tt.stale {
				writeTestFile(t, filepath.Join(stage, "stale.txt"), "stale")
			}
			got, err := stageGUIPackage(guiDir, notes, repo, stage)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.wantErr {
				return
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
			if b, err := os.ReadFile(filepath.Join(stage, "README.md")); err != nil || string(b) != "# WIREX Bridge v0.2.0\n" {
				t.Fatalf("README.md = %q err=%v", b, err)
			}
			if b, err := os.ReadFile(filepath.Join(stage, "WirexBridge.exe")); err != nil || string(b) != "fake-exe" {
				t.Fatalf("WirexBridge.exe = %q err=%v", b, err)
			}
			if _, err := os.Stat(filepath.Join(stage, "stale.txt")); !os.IsNotExist(err) {
				t.Fatalf("stale.txt should be removed, err=%v", err)
			}
		})
	}
}

func TestWritePackageZip(t *testing.T) {
	stage := t.TempDir()
	contents := map[string]string{
		"README.md":                     "# notes\n",
		"WirexBridge.exe":               "fake-exe",
		"licenses/dmr_signal/NOTICE.md": "notice",
	}
	for rel, body := range contents {
		writeTestFile(t, filepath.Join(stage, filepath.FromSlash(rel)), body)
	}
	files, err := collectInventory(stage)
	if err != nil {
		t.Fatal(err)
	}
	const top = "WIREX_Bridge_v0.2.0"
	zipA := filepath.Join(t.TempDir(), "a.zip")
	zipB := filepath.Join(t.TempDir(), "b.zip")
	if err := writePackageZip(zipA, top, stage, files); err != nil {
		t.Fatal(err)
	}
	if err := writePackageZip(zipB, top, stage, files); err != nil {
		t.Fatal(err)
	}
	sumA, err := fileSha256(zipA)
	if err != nil {
		t.Fatal(err)
	}
	sumB, err := fileSha256(zipB)
	if err != nil {
		t.Fatal(err)
	}
	if sumA != sumB {
		t.Fatalf("zip is not deterministic: %s != %s", sumA, sumB)
	}

	r, err := zip.OpenReader(zipA)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	wantNames := []string{
		top + "/README.md",
		top + "/WirexBridge.exe",
		top + "/licenses/dmr_signal/NOTICE.md",
	}
	if len(r.File) != len(wantNames) {
		t.Fatalf("got %d entries, want %d", len(r.File), len(wantNames))
	}
	for i, f := range r.File {
		if f.Name != wantNames[i] {
			t.Fatalf("entry %d = %q, want %q", i, f.Name, wantNames[i])
		}
		if strings.Contains(f.Name, "\\") || !strings.HasPrefix(f.Name, top+"/") {
			t.Fatalf("bad entry name %q", f.Name)
		}
		rel := strings.TrimPrefix(f.Name, top+"/")
		rc, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		b, err := io.ReadAll(rc)
		rc.Close()
		if err != nil || string(b) != contents[rel] {
			t.Fatalf("%s content = %q err=%v, want %q", f.Name, b, err, contents[rel])
		}
	}
}

func TestReadAppVersion(t *testing.T) {
	tests := []struct {
		name    string
		header  string
		missing bool
		want    string
		wantErr bool
	}{
		{"plain macro", "#define WIREX_VERSION_STR \"0.2.2\"\n", false, "0.2.2", false},
		{"indented with neighbours",
			"#ifndef WIREX_VERSION_RC_H\n#define WIREX_VERSION_MAJOR 0\n  #define WIREX_VERSION_STR \"1.10.3-rc.2\"\n#endif\n",
			false, "1.10.3-rc.2", false},
		{"missing macro", "#define WIREX_AUTHOR \"BI7KGD\"\n", false, "", true},
		{"bad version format", "#define WIREX_VERSION_STR \"0.2\"\n", false, "", true},
		{"missing file", "", true, "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := t.TempDir()
			if !tt.missing {
				writeTestFile(t, filepath.Join(root, "include", "wirex", "version_rc.h"), tt.header)
			}
			got, err := readAppVersion(root)
			if (err != nil) != tt.wantErr || got != tt.want {
				t.Fatalf("got %q err=%v, want %q wantErr=%v", got, err, tt.want, tt.wantErr)
			}
		})
	}
}

func TestCheckReleaseVersion(t *testing.T) {
	tests := []struct {
		name    string
		flag    string
		want    string
		wantErr bool
	}{
		{"matching", "v0.2.2", "0.2.2", false},
		{"mismatch", "v0.2.3", "0.2.2", true},
		{"prerelease mismatch", "v0.2.2-rc.1", "0.2.2", true},
		{"leading v stripped only once", "0.2.2", "0.2.2", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := t.TempDir()
			writeTestFile(t, filepath.Join(root, "include", "wirex", "version_rc.h"), "#define WIREX_VERSION_STR \"0.2.2\"\n")
			got, err := checkReleaseVersion(root, tt.flag)
			if (err != nil) != tt.wantErr || got != tt.want {
				t.Fatalf("got %q err=%v, want %q wantErr=%v", got, err, tt.want, tt.wantErr)
			}
			if tt.wantErr && !strings.Contains(err.Error(), "不一致") {
				t.Fatalf("error %q should mention 不一致", err)
			}
		})
	}
}

// TestAppVersionMatchesRepository guards the single source: the real header
// parses, and version.hpp derives its constant from the same macro.
func TestAppVersionMatchesRepository(t *testing.T) {
	root := filepath.Join("..", "..")
	v, err := readAppVersion(root)
	if err != nil {
		t.Fatalf("readAppVersion: %v", err)
	}
	if !plainVersionPattern.MatchString(v) {
		t.Fatalf("version %q is not X.Y.Z", v)
	}
	hpp, err := os.ReadFile(filepath.Join(root, "include", "wirex", "version.hpp"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(hpp), "app_version = WIREX_VERSION_STR") {
		t.Fatalf("version.hpp should derive app_version from WIREX_VERSION_STR")
	}
}

func TestManifestFiles(t *testing.T) {
	stage := t.TempDir()
	writeTestFile(t, filepath.Join(stage, "WirexBridge.exe"), "fake-exe")
	writeTestFile(t, filepath.Join(stage, "README.md"), "# notes\n")
	files, err := collectInventory(stage)
	if err != nil {
		t.Fatal(err)
	}
	got, err := manifestFiles(stage, files)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d files, want 2", len(got))
	}
	if got[0].Path != "README.md" || got[0].Size != int64(len("# notes\n")) || got[0].Sha256 != testSha256([]byte("# notes\n")) {
		t.Fatalf("README entry = %+v", got[0])
	}
	if got[1].Path != "WirexBridge.exe" || got[1].Sha256 != testSha256([]byte("fake-exe")) {
		t.Fatalf("exe entry = %+v", got[1])
	}
}
