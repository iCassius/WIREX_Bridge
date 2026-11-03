# Dear ImGui（第三方源码）

- 上游：https://github.com/ocornut/imgui
- 版本：tag `v1.92.9b`（master 分支稳定版，非 docking）
- Commit：`f1cc2ae15e53a861a874c3034aae6798fde194ab`（2026-07-31，"Version 1.92.9b"）
- 许可：MIT，见同目录 `LICENSE.txt`
- 获取方式：`git clone --depth 1 --branch v1.92.9b https://github.com/ocornut/imgui.git`

只保留核心源码（`imgui*.cpp/.h`、`imconfig.h`、`imstb_*.h`）与 `backends/imgui_impl_win32.*`、`backends/imgui_impl_dx11.*`。
未包含 demo、examples、docs、misc 和其它 backend。所有文件与上游字节一致、未修改；
`.gitattributes` 对 `third_party/imgui/**` 设置 `-text`，保留原始字节。

编译选项见 `tools/build-gui.ps1`：定义 `IMGUI_DISABLE_DEMO_WINDOWS`；ImGui 源码使用 `/W3`，本项目代码使用 `/W4`。
