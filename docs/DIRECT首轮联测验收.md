# DIRECT 首轮联测验收

## 验收结论

FTX-1 DIRECT 个人终端的自动手咪上行、BrandMeister 鹦鹉回声和电台扬声器播放闭环首轮验收通过。用户确认：“所有测试功能均已通过，电台回声清晰。”本次 native 会话持续 33.475 秒，完成一通语音呼叫并正常停止。

## 被测版本与配置

- 源码提交：`005c5e8e6d95a3ce2f29cf928d59e90c7551ffb1`；正式 clean build 的 26 项离线测试全部通过。
- 便携候选：`build/bm-radio-bridge-005c5e8`，root 已完成独立包审计。
- 电台接口：COM5；USB 音频 WaveIn 1、WaveOut 3；FTX-1 设为 HRI `ON`、Node Mode `DIRECT`。
- BM 预设：中国鹦鹉单呼 `parrot-cn`；呼号 `BI7KGD`、Gateway ID `461135501`、Source ID `4611355`、Master `43.129.83.124:62031`、单呼目标 `460997`、TS2、CC1。凭据不记录在本文。

## 会话证据

本机 JSONL 状态报告位于 `build/bm-radio-bridge-005c5e8/logs/bm-bridge-20261024-204652-639-d1f8639c.jsonl`。本文只记录结构化计数和事件名称，没有复制日志正文或语音数据。

| 指标 | 结果 |
| --- | ---: |
| 最终状态 | `stopped`，总时长 33,475 ms |
| BM failure | `none` |
| PTT observations / starts / ends | 37 / 1 / 1 |
| PTT timeout / rejects | 0 / 0 |
| TX / RX | 54 / 56 |
| BM calls started / ended | 1 / 1 |
| 播放帧 | 157 |
| 上行音频样本 | 149,280 |
| reconnects / rejected calls | 0 / 0 |
| RPTCL | 本机 UDP send succeeded |

日志记录了完整的呼叫与播放顺序：`tx_started_from_radio_ptt_down` → `tx_audio_draining_after_radio_ptt_release` → `hri_t3_write` → `hri_t3_observed_playback_enabled` → `hri_t0_write` → `downlink_call_drained_t0_observed`。这表明本次手咪按下启动一次上行，松开后完成音频排空；回声开始播放后，HRI T3 启播与 T0 收尾事件均被观察到，呼叫正常结束。

## 验收范围

本次 native 会话总时长为 33.475 秒，其中完成一通 FTX-1 DIRECT 个人终端语音呼叫；手咪按下到松开的上行采集时段为 3.136 秒。长时间连续待机、网络断开后的恢复、46001 静态订阅组呼收听、本地 RF 节点和 UI 操作流程仍需分别验收。
