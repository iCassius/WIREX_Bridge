# WIREX Bridge

本软件将电脑模拟为 MMDVM 设备，并与开启 HRI 模式的 Yaesu 电台连接模拟为 WIRES-X 服务器，实现 Yaesu 电台 WIRES-X 模式与 BrandMeister DMR 网络的高品质数字语音互通。

WIREX Bridge emulates an MMDVM device and acts as a WIRES-X server connected to a Yaesu transceiver in HRI mode, bridging Yaesu WIRES-X with the BrandMeister DMR network for high-quality digital voice communications.

> **测试电台声明 / Hardware Testing Notice**  
> 本项目目前**仅在 Yaesu FTX-1 上进行了完整实机开发与测试，尚未在除 FTX-1 之外的任何其他电台型号上进行过测试与验证**。  
> This project has been developed and verified **exclusively on the Yaesu FTX-1. It has NOT been tested or verified on any other transceiver models**.

---

## FTX-1 专项优化与适配 / Yaesu FTX-1 Optimizations

- **USB 单线集成与自动识别 / Single USB Cable Integration**  
  仅需一根 USB 数据线连接 FTX-1 与电脑，软件可自动枚举并精准匹配 FTX-1 的 HRI 串口、CAT 串口以及双向 USB 音频端点，免去繁琐的人工端口配置。  
  Requires only a single USB cable between the FTX-1 and the PC. The software automatically enumerates and binds the FTX-1's HRI COM port, CAT COM port, and USB audio input/output endpoints.
- **HRI 协议握手与链路守护 / HRI Handshake & Link Guardian**  
  原生支持 FTX-1 的 Direct 与 Access Point (AP) 模式协议交互，内嵌固定 HRI 握手模板；具备链路心跳守护，遇异常掉线时自动执行指数退避重连（3s / 6s / 10s）。  
  Native protocol implementation for both Direct and Access Point (AP) modes with embedded HRI handshake templates. Includes active link monitoring with automatic exponential backoff reconnection (3s, 6s, 10s).
- **双向 CAT 控制与参数同步 / Bidirectional CAT Synchronization**  
  实时双向同步 FTX-1 的工作频率（VHF/UHF）、调制模式（FM / C4FM-DN）与 TX 发射功率等级，可在 GUI 界面中动态调整并即时下发至电台。  
  Synchronizes operating frequency (VHF/UHF), operating modes (FM / C4FM-DN), and RF power levels between the GUI and FTX-1 in real time.
- **手咪物理 PTT 硬件联动 / Physical Microphone PTT Linkage**  
  全面打通手咪按键硬件事件：直接按下 FTX-1 标配手咪的物理 PTT 即可触发 DMR 网络上行呼叫，松开即刻结束，提供与真实中继完全一致的通联操控手感。  
  Direct hardware PTT binding: pressing the physical PTT key on the FTX-1 hand mic instantly initiates DMR network transmission without touching the keyboard or mouse.

---

## 一、电台操作步骤 / Radio Setup & Steps

1. **连接与启用 HRI / Connect & Enable HRI**  
   - 使用 USB 数据线将电台连接至电脑，进入电台设置菜单，将 **HRI 模式设为 ON**。  
   - Connect the transceiver to the PC via USB. Enter the radio menu and turn **HRI Mode ON**.
2. **选择 WIRES-X 模式 / Select WIRES-X Mode**  
   - 进入电台的 Radio 菜单 -> WIRES-X 设置，按需选择 **Direct**（直连）或 **Access Point (AP / PC 中继)** 模式。  
   - Navigate to Radio Menu -> WIRES-X settings, and select **Direct** or **Access Point (AP/PC Relay)** mode as needed.
3. **进入系统 / Enter WIRES-X System**  
   - **长按电台 GM 按键**，电台将进入 WIRES-X 连接与通信状态。  
   - **Long-press the GM key** on the transceiver to enter the WIRES-X interface.
4. **启动软件 / Launch Software**  
   - 运行本软件 `WirexBridge.exe`。  
   - Run `WirexBridge.exe`.

---

## 二、软件基础配置 / Software Configuration

在软件设置界面完成以下项配置（首次设置后将自动保存在本地 `config.json`）：  
Configure the following options in the settings interface (settings will be saved automatically to `config.json`):

- **a. DMR 凭据 / DMR Credentials**  
  - 填写您的呼号（Callsign）、DMR ID、BrandMeister Master 服务器地址及连接密码。  
  - Enter your Callsign, DMR ID, BrandMeister Master server address, and hotspot password.
- **b. 端口设置 / Port & Audio Settings**  
  - 选择电台对应的 **HRI 串口**、**CAT 串口**，以及电台音频的输入/输出端点设备。  
  - Select the radio's **HRI COM port**, **CAT COM port**, and the corresponding USB audio input/output endpoints.
- **c. 组呼收听与订阅 / Talkgroup (TG) Listening & Subscription**  
  - **动态组 / Dynamic Groups**: 在软件频道列表中直接添加或选择目标通话组（例如 TG 91、TG 46001 等）即可即时收听与发起呼叫。  
    Add or select target Talkgroups (e.g., TG 91, TG 46001) in the channel list to listen and transmit on demand.
  - **静态组 / Static Groups**: 填入 BrandMeister API Key 后，可直接在软件内查询、添加或注销服务器端绑定的静态组。  
    Provide your BrandMeister API Key to query, add, or drop server-side static talkgroups directly from the GUI.
- **d. 建立连接 / Link Connection**  
  - 配置完成后，点击 **「连接串口」** 接管电台链路，再点击 **「连接 BrandMeister」** 接入 DMR 网络。  
  - Once configured, click **"Connect Serial"** to link the radio, then click **"Connect BrandMeister"** to join the DMR network.

---

## 三、通联收发操作 / QSO & Operation

1. **选择目标组 / Select Target Group**  
   - 在频道列表中选中当前要通联的目标通话组（TG）。  
   - Select the desired Talkgroup (TG) in the channel list.
2. **发射呼叫 (TX) / Transmit (TX)**  
   - 无需在电脑键盘上操作，直接**按住电台手咪的物理 PTT 键**即可向所选通话组发起呼叫。  
   - No PC interaction needed: simply **press the physical PTT button on your microphone** to transmit to the selected TG.
3. **接收来话 (RX) / Receive (RX)**  
   - 当网络有语音呼入时，电台扬声器将实时输出清晰声音，软件控制台同步回显来话者的呼号与 DMR ID。  
   - When a call arrives from the network, audio will play through the radio's speaker in real time, and the caller's callsign and DMR ID will be displayed in the console.
4. **断开与退出 / Disconnect & Exit**  
   - 通联结束后，点击 **「断开串口」**（程序会先安全注销 BM 会话并释放硬件端口），然后退出电台的 WIRES-X 模式并关闭软件。  
   - When finished, click **"Disconnect Serial"** (safely closes the BM session and releases hardware ports), exit WIRES-X mode on the radio, and close the software.

---

## 四、注意事项与合规提示 / Notices & Compliance

> ### 提示 / Important Security Notice
> `config.json` 会在本地明文保存您的 BrandMeister 访问凭据（包括热点密码和 API Key），请妥善保管该文件，**切勿分享给他人或提交上传至公共代码仓库**。  
> `config.json` stores your BrandMeister credentials (hotspot password and API key) in plain text locally. Keep this file secure and **never share it or upload it to public repositories**.

> ### 合规提示 / Regulatory & Compliance Notice
> 本项目仅供持有合法业余无线电执照的爱好者进行实验研究与学术交流。在使用本软件连接真实电台或发射射频信号前，请务必遵守当地无线电管理法规，并严格使用您本人的呼号与 DMR ID；严禁冒用他人身份或无证发射。  
> This project is intended strictly for experimental research and educational use by licensed amateur radio operators. Before connecting to a physical transceiver or transmitting RF signals, ensure full compliance with your local radio regulations and always use your own callsign and DMR ID. Do not impersonate other stations or transmit without authorization.
>
> FM 中继为实验性功能，并非 Yaesu 官方功能。  
> The FM relay is an experimental feature and is not an official Yaesu feature.

---

## 五、许可协议 / License

本项目采用 **GNU General Public License v3.0 or later (GPL-3.0-or-later)** 开源协议发布，完整许可证文本请参阅 [LICENSE](LICENSE)。  
This project is licensed under the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**. See [LICENSE](LICENSE) for details.

### 第三方开源组件 / Third-Party Components

- `third_party/dmr_signal` — GPL-3.0-or-later，详见 [third_party/dmr_signal/NOTICE.md](third_party/dmr_signal/NOTICE.md)
- `third_party/droidstar_mbe` — GPL-3.0-or-later（其中 mbelib 派生部分附带 ISC 许可），详见 [third_party/droidstar_mbe/ISC-NOTICE.txt](third_party/droidstar_mbe/ISC-NOTICE.txt)
- Dear ImGui (`third_party/imgui`) — MIT License，详见 [third_party/imgui/LICENSE.txt](third_party/imgui/LICENSE.txt)
