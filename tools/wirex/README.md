# wirex 命令速查

TODO 3.2 的 Go 运维 CLI。只用标准库，仅支持 Windows。第一版包装现有 PowerShell 脚本，clean-tree 检查、provenance、日志校验等发布门槛仍由脚本负责。

```powershell
go build -o build/wirex.exe ./tools/wirex   # 仓库根 go.work 引用本模块
go test ./tools/wirex; go vet ./tools/wirex
```

| 命令 | 作用 |
| --- | --- |
| `wirex doctor` | 检查 Go、Git、CMake（可选）、VS 2019 + vcvars64 + cl/link、Windows PowerShell 5.1、COM 串口（注册表 SERIALCOMM）、音频终结点、工作树是否干净、`private/fixtures/device-y.bin`。有 FAIL 时退出码为 1 |
| `wirex build [--compile-only]` | 调用 `tools/build-bm-bridge.ps1`（固定 Release `/O2 /MT`）。输出按控制台代码页解码，写成 UTF-8 日志 `build/_work/<构建目录名>.log`，可直接作为 `package-release.ps1 -BuildLogPath` 使用 |
| `wirex build --with-launcher` | 额外调用 `tools/build-launcher.ps1`，输出到 `build/_work/wirex-launcher-<sha7>-<ts>/` |
| `wirex build --cmake [--debug]` | 用 VS 2019 生成器构建 `CMakeLists.txt`，并运行 CTest。需要 cmake（本机目前没有）。产物不带 provenance，不能用于打包 |
| `wirex test [--offline]` | 运行当前 HEAD 最新完整构建中的 40 项 Native 测试 exe（清单从 build-bm-bridge.ps1 解析），以及 `psOfflineTests` 切片中的 PowerShell 测试（缺少的脚本会跳过并警告；UI 测试使用 `-STA`） |
| `wirex test --all` | 先完整构建 Native 与 launcher，再执行上面的测试 |
| `wirex test --build-dir D --launcher P --run S` | 指定构建目录、launcher exe，或按名称子串筛选测试 |
| `wirex package --version V` | 调用 `tools/package-release.ps1`。会自动查找最新的干净完整构建及其 `.log`、当前 HEAD 的 launcher 构建和 fixture。各项都可以用 `--build-dir/--build-log/--launcher-dir/--fixture/--native-repo` 覆盖 |
| `wirex package --version V --zip` | ZIP-only 版本（v0.1.1-test.2 / v0.1.1）在 root 审计后调用 `New-ZipOnlyReleaseDistribution`，ZIP 输出到 `build/_work/r126-distribution/V/` |

正式发布流程：在干净工作树上依次执行 `wirex build --with-launcher`、`wirex test`、`wirex package --version V`；root 审计后执行 `wirex package --version V --zip`。
