# 首个 Release 验收

## 发布目标和当前状态

目标版本为私有 GitHub 预发布 `v0.1.0-alpha.1`。本文件只定义发布核对项；当前没有创建版本 tag、最终便携包或 GitHub Release，也没有执行最终包 HIL。最终源码 commit、逐文件资产清单和 SHA-256 由根会话在打包审计后更新。

根会话记录的正式 clean build 基于 `eafc8a1`，使用 Windows PowerShell 5.1 / VS 2019 x64；27 项离线测试全部通过，warning/error 均为 0。构建目录为 `build/_work/wirex-bridge-eafc8a1-20261025-071535`，日志为 `build/_work/bm-profile-eafc8a1-build.log`。其后 `0a84013` 相对 `eafc8a1` 的改动只涉及文档和 `tools/bm-radio-bridge-README.md`，源码、测试和构建脚本没有变化。此 build 记录不等于最终便携包审计或最终包实机验收。

已有实机结果必须按版本分别记录：用户确认 `005c5e8` 的一通 DIRECT 手咪 → BM 鹦鹉 → 电台扬声器闭环清晰；用户另确认 `ab3c5fa` 的 TG91 实机收听正常。这两项结果不代替 `v0.1.0-alpha.1` 最终包的 HIL。最终包 HIL 目前未执行。

## 构建与资产核对

- [ ] 根会话确认源码树干净，记录最终 commit 和 builder 输入；使用仓库内 `tools/build-bm-bridge.ps1` 从该源码构建，不复用历史 EXE。
- [ ] 27 项离线测试在最终源码上全部通过；记录构建 warning/error、日志路径和 EXE SHA-256。
- [ ] 使用同一 clean build 生成便携目录；逐文件核对路径、长度和 SHA-256，确认没有混入旧版二进制或不同提交的启动器。
- [ ] 运行包内 `--help`、设备列表 schema 和启动器静态检查，确认默认 preset、设备 identity guard、`start-profile.cmd` 和只收 preset 入口对应本次源码。
- [ ] 包内不含 BM 密码、用户创建的 `connection-profile.json`、`audio-settings.json`、运行期 `logs/`、临时日志或测试语音。用户首次运行后再在本机创建 profile/settings；密码单独由用户放入 private 文件或在控制台隐藏输入。
- [ ] README、许可证和其他必要文件与程序放在正确相对路径。私有 GitHub Release 使用独立文件资产并提供路径映射 manifest；本项目不生成 ZIP。
- [ ] 发布资产标明与二进制相符的源码 commit，并随私有 tag 提供完整对应源码和 `tools/build-bm-bridge.ps1`。在资产审计完成后再写入最终 tag、清单和 SHA-256；本轮文档工作不创建 tag 或 Release。

## 许可材料复核

- [ ] 检查 `third_party/dmr_signal/NOTICE.md` 与 `COPYING.GPL-3.0.txt`，并把对应许可/notice 放入最终资产。
- [x] 根会话已核对固定 DroidStar commit `becf1dede57c4a70a865e9cb4cac9247e505599a`：项目根目录和 `imbe_vocoder` 目录均没有 `COPYING` 或全局 `LICENSE`。57 项 `source-manifest` 保留逐文件来源/许可记录；实际编译的 27 项中，21 项标为 GPL-3.0-or-later、4 项标为原文件内 ISC 文本、`imbe_vocoder_impl.cc` 只记录 attribution、`imbe_vocoder.cc` 没有文件内许可/版权文本。后两种状态应如实随源清单提供，不据单文件 header 缺失自动判为不授权，也不虚构项目级 GPL 覆盖。
- [ ] 包内继续提供 `third_party/dmr_signal/NOTICE.md`、对应 GPL-3.0 文本、DroidStar `source-manifest`、源码和构建脚本；记录有文件级许可文字与仅有 attribution 的分布。不要据此替项目第一方代码擅自选择新的总许可证，也不要宣称全项目法律审查已经完成。

## 最终包硬件/网络验证

最终候选以可见控制台运行。测试前连接 FTX-1 USB、设 HRI `ON` 和 Node Mode `DIRECT`、退出官方 WIRES-X 程序，并使用测试操作者自己的 BM 账户和独立密码。日志或报告不得记录密码、原始音频、协议正文或临时抓包。

| 项目 | 最终包检查 | 通过依据 | 状态 |
|---|---|---|---|
| 默认 DIRECT Echo | 使用操作者自己的 BM profile，等待 HRI/BM 就绪，先松开 PTT，再按住手咪说话并松开；等待 BM 鹦鹉回声从电台扬声器播放，最后按 `Q`。 | 日志显示一次 PTT start/end、BM call start/end 和播放完成；用户独立确认听到清晰回声；进程有界退出。 | 未执行 |
| 物理 PTT 边沿与限制 | 确认 ready 后先见松开再 arm；一次按下只开始一通，持续按住不重复切换，松开结束并允许下一通。若安排完整期限测试，单次呼叫上限为 120 秒。 | 日志与用户操作顺序一致；不把 120 秒限制外推为 BM/RF 端超时。 | 未执行 |
| TG91 只收 | 在操作者自己的 Gateway 上设置 TS2 TG91 静态订阅，运行该 Gateway 对应的 receive-only profile。 | 听到允许的下行呼叫；程序不因手咪/键盘输入发起上行。保留呼叫和时隙过滤。 | 未执行 |
| TG46001 只收 | 使用 `listen-46001` 或对应只收 profile 等待组呼。 | 只接受目的 TG46001、TS2、组呼；不得向该组呼发射，不能以放宽到全部组呼作为测试方法。 | 未执行 |
| 双向增益 | 分别调整 radio playback 和 mic transmit gain，在最终包中听音比较并检查削顶统计。 | 两项设置互相独立且重启后保留；正常讲话不出现不可接受削顶。历史版本的听音不代替本包检查。 | 未执行 |
| `Q` 收尾 | 空闲和单通话/回放期间分别退出。 | 进程按有界清理退出；报告说明 PC 资源关闭情况。`radio_state` 保持 `unknown`，没有电台 ACK 时不写成 RF/PTT 已停止。 | 未执行 |
| 空闲待机与网络恢复 | 按最终联测计划进行有界长时间待机，并检查空闲/播放期间网络断开后恢复。 | 报告能区分 ready 丢失、重连和恢复；断网前的媒体不会迟到播放。 | 留待最终集中联测 |

## 不属于本 Release 的功能

- FTX-1 LCD 显示 BM 当前呼号、房间或通话目标尚未实现。
- DIRECT 下 Bridge 运行时的 RF 接收路由尚未测定；本 alpha 不提供 BM 下行到 RF 的发射功能，也不控制 FTX-1 CAT/AP Node Mode。
- 图形 UI 没有连接到真实核心或设备，本 Release 通过可见控制台操作。
- 软件 ready、发送计数、`Q` 正常退出和 PC 资源关闭都不表示电台 RF 状态已验证。

完成 checklist 后，根会话再对齐发布说明中的最终 commit、tag、资产路径映射和逐文件 SHA-256。用户本地 HIL 结果作为最终包证据单独加入记录；未执行项继续标为待验，不得改写成通过。
