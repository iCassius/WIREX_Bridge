# 首个 Release 验收

## 发布目标和当前状态

私有 GitHub 预发布 [v0.1.0-alpha.1](https://github.com/iCassius/WIREX_Bridge/releases/tag/v0.1.0-alpha.1) 已发布，Release ID `423365682`，发布时间为 2026-10-25 19:49:48（中国标准时间）。源码 tag 指向 `312e7142a419566c47a335fb83a33c756aaf69f3`。Release 有 18 个已上传 assets。

该 tag 的正式 clean build 通过 27 项离线测试，warning/error 均为 0。构建目录 `build/_work/wirex-bridge-312e714-20261025-113013`，日志 `build/_work/release-312e714-build.log`，EXE SHA-256 `adbec34fde41565f437283fde3a7a46f28f3615dc1575d90086158e08a4fb1aa`。本机绿色目录为 `build/releases/v0.1.0-alpha.1`；manifest 列出 16 个普通文件，加上 manifest.json 共 17 个文件，manifest SHA-256 `21d2e617f7761b6cc28a467432fb4c9d50d7c5ecafe2c1524afb8f9562fab9f5`。该目录不打 ZIP，未包含密码、连接 profile、音量设置或运行日志。

根会话确认远端 18 个 assets 全部上传。下载器在草稿和正式 published 路径均通过验收；正式下载重建 17 个文件，其路径、长度和 SHA-256 与本机绿色目录一致。普通 Release asset 由 manifest 列出；下载脚本是独立的额外 asset。

`005c5e8` DIRECT 手咪回声与 `ab3c5fa` TG91 收听是前序版本的用户确认，不能代替本 Release 的 HIL。本 Release 的硬件/网络 HIL 尚未执行。当前 FTX-1 LCD 话者显示、Bridge 运行期间 RF 路由、BM 到 RF 发射和真实图形 UI 不属于本 Release。

发布操作使用的 `main` 提交为 `86e9d105e3095b18b1363b550d9dc6cda8e49552`，相对 tag 只包含 `tools/publish-release.ps1` 和对应测试的发布器修复；后续交接文档提交不改变发布 tag 或资产。二进制和 manifest 对应准确源码 tag `312e714...`。

## 构建与资产核对

- [x] 根会话确认发布源码树干净；使用仓库内正式 builder 从 tag 对应源码构建。
- [x] 27 项离线测试全部通过，warning/error 为 0；日志与 EXE SHA-256 见上方发布记录。
- [x] 本机绿色目录由同一 clean build 生成，逐文件路径、长度和 SHA-256 已核对。
- [x] 包内 help、音频 schema、启动器静态检查和 PS5.1 mock 均通过。
- [x] 包内不含 BM 密码、用户创建的连接 profile、音量设置、运行日志或测试语音；首次运行后由用户在本机生成设置。
- [x] README、许可证和所需文件的相对路径已审计；Release 使用独立文件 assets 和 manifest，不生成 ZIP。
- [x] 已发布的 assets 对应源码 tag `312e714...`；tag 提供完整源码、构建脚本、许可和来源材料。

## 许可材料复核

- [x] 已检查 `third_party/dmr_signal/NOTICE.md` 和 `COPYING.GPL-3.0.txt`，并将许可/notice 放入资产。
- [x] 根会话已核对固定 DroidStar commit `becf1dede57c4a70a865e9cb4cac9247e505599a`：项目根目录和 `imbe_vocoder` 目录均没有 `COPYING` 或全局 `LICENSE`。57 项 `source-manifest` 保留逐文件来源/许可记录；实际编译的 27 项中，21 项标为 GPL-3.0-or-later、4 项标为原文件内 ISC 文本、`imbe_vocoder_impl.cc` 只记录 attribution、`imbe_vocoder.cc` 没有文件内许可/版权文本。后两种状态应如实随源清单提供，不据单文件 header 缺失自动判为不授权，也不虚构项目级 GPL 覆盖。
- [x] 包内提供 GPL notice、DroidStar source-manifest、对应源码和构建脚本；文件级来源与许可情况随 source-manifest 记录。

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

构建、资产审计、发布和 published 下载验证已完成。最终包 HIL 结果待用户完成集中联测后补记；未执行项保持待验。
