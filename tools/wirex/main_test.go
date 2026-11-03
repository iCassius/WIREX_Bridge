//go:build windows

package main

import (
	"errors"
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
		{"explicit release", []string{"--release"}, buildOptions{}, false},
		{"compile only", []string{"--compile-only"}, buildOptions{CompileOnly: true}, false},
		{"cmake debug", []string{"--cmake", "--debug"}, buildOptions{CMake: true, Debug: true}, false},
		{"with launcher", []string{"--with-launcher"}, buildOptions{WithLauncher: true}, false},
		{"gui only", []string{"--gui"}, buildOptions{GUI: true}, false},
		{"gui with explicit release", []string{"--gui", "--release"}, buildOptions{GUI: true}, false},
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
