# WIREX Bridge

本软件模拟为 MMDVM 设备，并与开启 HRI 模式的 Yaesu 电台连接模拟为 WIRES-X 服务器，实现电台 WIRES-X 模式与 BrandMeister DMR 网络互通。

> **合规提示 / Compliance Notice**
>
> 本项目仅供持有合法业余无线电执照的爱好者进行实验研究。使用本软件连接真实电台或发射前，请遵守当地无线电管理法规，并使用你本人的呼号与 DMR ID；不得使用他人身份。
>
> This project is for experimental research only by licensed amateur radio operators. Before connecting to a real radio or transmitting, comply with your local radio regulations and use your own callsign and DMR ID. Do not use another person's identity.
>
> FM 中继为实验功能，并非 Yaesu 官方功能。The FM relay is experimental and is not a Yaesu feature.

> **版本说明**：当前发布为 v0.2.0 原生单 EXE GUI，界面与本页早期的 WPF 描述不同，详见 [docs/releases/v0.2.0.md](docs/releases/v0.2.0.md)。

---

## 一、电台操作步骤

1. **连接与启用 HRI**：使用 USB 线将电台连接至电脑，进入电台菜单将 **HRI 模式设为 ON**。
2. **选择 WIRES-X 模式**：进入电台 Radio 菜单中的 WIRES-X 选项，按需配置为 **Direct** 或 **Access Point (AP/PC 中继)** 模式。
3. **进入系统**：**长按电台 GM 按键**，进入 WIRES-X 连接界面。
4. **启动软件**：打开本软件 `WirexBridge.exe`。

---

## 二、软件基础配置

在软件设置界面完成以下项配置（首次设置后自动保存在本地 `config.json`）：

- **a. DMR 凭据**：填写个人呼号（Callsign）、DMR ID、BrandMeister Master 服务器及连接密码。
- **b. 端口设置**：选择电台对应的 **HRI 串口**、**CAT 串口**，以及电台音频的输入/输出端点。
- **c. 组呼收听与订阅**：
  - **动态组**：在软件频道列表中直接添加或选择目标 TG（如 TG 91、TG 46001 等）即可直接收听与起呼；
  - **静态组**：填入 BrandMeister API Key，可通过软件直接查询、添加或退订服务器端绑定的静态组。
- **d. 连接链路**：配置完成后，点击 **「连接串口」** 接管电台链路，再点击 **「连接 BrandMeister」** 接入网络。

---

## 三、通联收发操作

1. **选择目标组**：在频道列表中选中要通联的目标通话组（TG）。
2. **发射（TX）**：无需在电脑键盘操作，直接**按下电台手咪的物理 PTT 键**即可向所选目标发起呼叫。
3. **接收（RX）**：网络来话时，电台喇叭将实时输出声音，软件控制台同步回显来话者的呼号与 DMR ID。
4. **断开与退出**：通联结束后，点击 **「断开串口」**（将先安全切断 BM 会话再释放端口），退出电台 WIRES-X 模式并关闭软件即可。

---

> **提示**：`config.json` 会明文保存您的 BM 访问凭据，请妥善保管，切勿分享给他人或上传至公共仓库。

---

## License / 许可

本项目以 GNU General Public License v3.0 or later（GPL-3.0-or-later）发布，完整文本见根目录 [LICENSE](LICENSE)。

This project is released under the GNU General Public License v3.0 or later (GPL-3.0-or-later). See [LICENSE](LICENSE) for the full text.

第三方组件 / Third-party components:

- `third_party/dmr_signal` — GPL-3.0-or-later，见 [third_party/dmr_signal/NOTICE.md](third_party/dmr_signal/NOTICE.md)
- `third_party/droidstar_mbe` — GPL-3.0-or-later，其中 mbelib 派生部分附带 ISC 许可，见 [third_party/droidstar_mbe/ISC-NOTICE.txt](third_party/droidstar_mbe/ISC-NOTICE.txt)
- Dear ImGui（`third_party/imgui`）— MIT，见 [third_party/imgui/LICENSE.txt](third_party/imgui/LICENSE.txt)
