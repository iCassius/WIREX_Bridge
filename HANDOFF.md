# WIREX Bridge 交接入口

## 当前交接摘要（2026-11-05 · R128 · a7081af）

### HRI 实机连接待核查
- 用户报告当前实机无法连接。“两串口波特率混淆”只是待验证假说。源码证据：`src/engine/win_io.hpp:168–193` 固定 HRI 为 115200、8N1；`src/app/radio_cat.cpp:473–476` 按配置波特率建立 CAT 8N2 会话；默认 38400 见 `include/wirex/app/config.hpp`。GUI 波特率选择只设置 CAT。
- HRI 打开串口后会预排空最多 250 ms/4096 B，观察 20 ms 安静，再等待 V 响应最多 2500 ms；随后每 1000 ms 发 Y，等待 Y/0 最多 3000 ms。只有收到 Y/0 且 WaveOut 打开后才报告 `hri_ready`（`src/engine/win_io.hpp:725–764`、`include/wirex/hri_session.hpp:11–15`、`src/engine/engine_loop.cpp`）。`hri_session` 在 8e2 到 a7081af 之间未改；`engine_loop` 的连接编排变化较大，现场失败原因仍未确定。
- [ ] 获得用户授权后，核对实际 COM 与设备的对应关系、电台当前串口设置；使用相同配置对照旧/新版本，并保存完整 V/Y 收发记录。测试前保留现有配置，过程不发射。

### BM 本机播放与射频边界
- BM 本机 WaveOut 离线路径已通过。`tests/engine_test.cpp` 中已有 `test_hri_healthy_waveout_downlink_end_to_end`，覆盖健康假 HRI/WaveOut 下行路径；旧文档称缺少此测试的内容已过时，本摘要不重写旧文档。真实 BM 来话听音仍待验。
- Native 41/41 的记录来自 `source_commit=8e2` 且标记 dirty 的构建 provenance；该快照包含 BM-only Engine fake 测试。app 14/14 来自当时的离线执行记录，没有逐文件 provenance。本轮两组测试均未重跑；没有证据断言两组结果对应同一逐文件源码快照，也未核对它们与 a7081af 的逐文件关系。
- AP/PC C4FM/FM 射频转发尚未实现。旧文档中涉及转发路径的推断仍待验证，不能作为已实现行为引用。

### UI、音频待办与本机交付
- 100% DPI 的 1360×900 同尺寸文字截图只显示有限的边缘改善；125% DPI 尚未验证。
- `app/TODO.md` 中预先存在的 112 行音频专项保持原样，其中的根因判断与修复建议是待验证假设，不作为已确认结果。
- R128/a7081af 单 EXE 交付保留在本机，未推送。交付时目录只有 EXE；运行后已生成 `config.json` 和 `private/`，现存文件保留。本轮没有读取或修改这些配置及运行数据。

### 后续待办
- [ ] 验证 TG46001 的真实接收，以及自动组呼流程与 BM 连接之间的联动。
- [ ] 将 BM RTT 指标接入主界面，并核对数据来源与暂无数据状态。
- [ ] 在 125% DPI 下验收字体、控件边界与 IME 输入/候选窗口。
- [ ] 先获用户授权进行只读接收观察，检查 AP/PC CAT 静噪及 FM/C4FM 链路；如需发射完成双向验收，另行取得明确授权。
- [ ] 后续整理 `docs/ARCHITECTURE.md`、R128 交接及相关架构文档，更新为当前实现事实。
- [ ] 核对单 EXE 首次启动时的配置生成、版本追溯信息与发布范围，保留现存配置和运行数据。
- [ ] 音频专项原文继续保留；根因和修复建议仍待测量、听音验证后再确认。

---

以下为 2026-11-04 R127 历史记录，当前状态以上述摘要为准。

更新：2026-11-04（R127）。本文只记录当前状态。更早的逐轮交接（R103–R125）可通过 `git log -- HANDOFF.md` 或 `git show 1283f86:HANDOFF.md` 查看。系统组成见 [ARCHITECTURE](docs/ARCHITECTURE.md)，待办以 [TODO](TODO.md) 为准。

## 当前版本

| 项 | 状态 |
| --- | --- |
| `main` | 已包含 R126（运行状态收尾修正、来话历史分页、UI 调整、ZIP-only 发布工具、图标）以及 R127 清理 |
| stable `v0.1.0` | tag 指向 `c12b50a9f339417ffd49d37b7acab6057fa51bcf`，GitHub Release 已发布（`prerelease=false`）；发布审计见 [R124_RELEASE](docs/R124_RELEASE.md) |
| 本机测试目录 | `build/releases/v0.1.1-test.1`（R125 本机测试包，不是正式 release）；回退版本 `build/releases/v0.1.0` |
| R126 ZIP-only | profile `v0.1.1-test.2`/`v0.1.1` 已在 `tools/ZipOnlyRelease.psm1` 中；**尚未打包**，也没有 tag 或 Release |

R126 的设计与验收：[R126_DELIVERY](docs/R126_DELIVERY.md)、[R126_RUNTIME](docs/R126_RUNTIME.md)、[R126_UI](docs/R126_UI.md)、[R126_I18N](docs/R126_I18N.md)。

## R127 清理（2026-11-04）

- **tools/**：文件数从 112 降到 57。删除了 alpha8–19 启动器、旧 alpha release profile、HRI 诊断启动器及其测试。v0.1.0 profile 已内联到 `tools/package-release.ps1`，并已与已发布的 manifest 逐项核对，结果一致。
- **编译中间产物**：删除了根目录和 `app/` 下散落的 `*.obj`；`.gitignore` 现在在任意层级忽略 `build/`、`tmp/`、`*.obj`、`__pycache__/` 等。
- **私有历史**：`private/build-retired` 与 `build-history`（R110–R124，共 26407 个文件、3.85 GB）先压缩为 `FTX1_project/_archive/wirex-private-history-R110-R124.7z`（434 MB，`7z t` 校验通过），然后从工作区删除。
- **旧 worktree**：`native-build-R126` 和 `r124-stable-release` 的 `build/` 已归档为 `_archive/wirex-worktree-builds-R124-R126.7z`（910 个文件），两个 worktree 均已移除。
- **docs/**：
  - 删除 112 份过时文档：`docs/` 下 70 份（R104–R125 的逐轮交接、发布交接、UI/CAT/RUNTIME 记录，S1-*/S3-A 验收，早期计划与联测清单）和 `docs/releases/` 下 42 份（`v0.1.0-alpha.*` 的发布说明、包 README 和构建审计）。这些文件仍可从 git 历史找回。
  - 移到 `docs/research/` 的有 22 份研究资料，以及 2 份 R110 证据索引（`docs/research/evidence/`）。移动后已修正相对链接，指向已删文档的链接改为纯文本。
  - 留在 `docs/` 根目录的有 20 份，另加新建的 `ARCHITECTURE.md`；`docs/releases/` 保留 5 份。

## 环境注意事项

- **从 Git Bash 调用 Windows PowerShell 5.1**：必须先重置模块路径，否则会继承 PowerShell 7 的路径，导致 `Get-FileHash` 等命令找不到：
  ```sh
  PSModulePath='C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules' \
    powershell.exe -NoLogo -NoProfile -STA -File tools/test-ui-console.ps1
  ```
- **编码**：`.ps1`/`.psm1` 必须保留 UTF-8 BOM。PS5.1 会把无 BOM 的文件按本机 ANSI 读取，中文字符串会变成乱码，甚至导致解析失败。
- **测试前置条件**：`private/fixtures/device-y.bin`（HRI 模板）、`build/releases/v0.1.0`（已发布包目录）和本地 `v0.1.0` tag。三者都不在 Git 工作树中，新 worktree 需要另行准备。

## 构建与测试（`wirex` CLI）

```sh
go build -o build/wirex.exe ./tools/wirex   # 仓库根，go.work 已配置
build/wirex.exe doctor                      # 环境检查：MSVC/PS5.1/COM/音频/工作树/fixture
build/wirex.exe build [--compile-only] [--with-launcher]
build/wirex.exe test --offline              # Native 40 + PowerShell 离线回归
build/wirex.exe package --version v0.1.1 [--zip]
```

`wirex` 第一版包装现有的 `build-bm-bridge.ps1`、`build-launcher.ps1` 和 `package-release.ps1`，并会自动重置子进程的 `PSModulePath`、把 vswhere 加进 PATH。命令说明见 [tools/wirex/README](tools/wirex/README.md)。

**基线**（main `847a461`，2026-11-04 实测）：
- 干净工作树完整构建：Native 40/40、launcher 编译通过；全新 checkout 的 compile-only 构建也已验证（vendor 字节修复见下）。
- `wirex test --offline`：**52 项通过、0 失败**（Native 40 + PowerShell 12：package-release 214、publish-release 66、download-release、r126-zip-only 26、launcher、portable-config 69、ui-localization 108、ui-render、ui-channels 186、ui-console 121、ui-status 87、channel-activation-state 348）。
- 也已通过：`test-ui-audio-gain` 93、`test-package-ui-contract` 30、`test-bridge-user-config`、`test-start-bm-radio-bridge`。

**已知失败**（都是 R126 改了 UI、旧断言没跟上；main `405426f` 上同样失败）：
- `test-ui-r124`：点击 `CatBaudRateBox` 后下拉列表没有打开。这是一项真实 WPF 鼠标输入测试，需要前台窗口。
- `test-ui-radio-cat`：缺少的本地化模块导入已补上；现在失败在来话历史分页断言（“超过五条来话后……页码未正确建立”），需要按 R126 的分页规则更新。

**vendor 字节**：`third_party/droidstar_mbe/upstream/**` 已标记为 `-text`。上游原文件是 CRLF/LF 混合行尾，由 `source-manifest.json` 锁定 SHA-256；之前 Git 把它们规范化为 LF，导致全新 checkout 构建失败，现已修复。

## 实机待办

见 [TODO](TODO.md) 第一节：
- 1.1 R126 收尾：集成运行复核、TG46001 动态组实际收听、图标显示。
- 1.2 电台与射频实机核对：BM↔FM/C4FM 双向、CAT 能力边界、LCD 可重复性观察、听音对照。

本仓库目前没有任何实机验收结果覆盖 R126。

## 文档索引

| 文档 | 用途 |
| --- | --- |
| [README.md](README.md) | 用户使用说明（用户维护，不随交接修改） |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 当前系统架构：组件、进程、IPC、配置、发布结构、构建与测试入口 |
| [TODO.md](TODO.md) | 权威待办清单 |
| `docs/R126_*.md` | 当前轮次的设计与验收记录 |
| [docs/R124_RELEASE.md](docs/R124_RELEASE.md) | v0.1.0 发布审计记录 |
| `docs/releases/` | `v0.1.0.md`、`v0.1.1-test.2.md`、`v0.1.1.md` 是 Release 正文，由 `publish-release.ps1` 按 tag 读取；`v0.1.0-package-README.md`、`v0.1.1-test.1-local-README.md` 是打包脚本使用的包内 README |
| `docs/` 下其余 14 份（`BM来话身份显示`、`R106_*`、`R108_*`、`R109_*`、`R112_A_网络音频指标`、`R113_*`、`R116_*`、`连接配置`、`配置与桌面操作`、`音量调节`） | v0.1.0 包内 `runtime/docs/` 文档。打包、下载脚本和测试按路径与内容引用它们，**不能改名，也不能修改内容**（即使里面有失效链接） |
| `docs/DMR通话实现.md` | DMR FEC/LC 上游来源说明，`include/wirex/dmr_call.hpp` 按路径引用 |
| `docs/research/` | 独立研究资料：AMBE/C4FM 参数映射、BM 协议与 API、HRI 记录与 PTT、WIRES-X 官方软件功能与屏幕研究、RF 节点计划、LCD 审计等。只记录研究当时的结论，不代表当前实现 |

改动 `docs/` 前，先用下面的命令确认文件没有被代码引用：

```sh
git grep -ohE "docs[\\\\/][^'\" )\`|]+\.md" -- tools ui src tests include
```
