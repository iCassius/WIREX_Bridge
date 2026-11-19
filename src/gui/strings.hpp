#pragma once

// GUI 文案表：键 → zh-CN 源文案 / en-US 译文。
// en-US 优先复用 ui/windows/UiLocalization.psm1 词典中的译文；词典里没有的条目在行尾标注 "new"。
// 运行时支持中英文切换；用户选择保存在 config 的 ui.language。
// 含 printf 占位符的条目两列占位符顺序与类型必须一致。

#include <cstddef>
#include <cstdint>
#include <atomic>
#include <string_view>

namespace wirex::gui {

// clang-format off
#define WIREX_GUI_STRINGS(X) \
    X(app_title,            "WIREX BRIDGE  ·  FTX-1",              "WIREX BRIDGE  ·  FTX-1") \
    X(window_title,         "WIREX Bridge v%s — FTX-1 · by %s",    "WIREX Bridge v%s — FTX-1 · by %s") \
    X(brandmeister,         "BrandMeister",                        "BrandMeister") \
    X(bm_disabled,          "未连接",                              "Not connected") \
    X(bm_resolving,         "BM 主站名称解析中",                   "Resolving BM server name") \
    X(bm_connecting,        "连接中",                              "Connecting") \
    X(bm_connected,         "已连接",                              "Connected") \
    X(bm_backoff,           "重试中",                              "Retrying") \
    X(bm_failed,            "连接失败",                            "Connection failed") \
    X(rtt,                  "RTT",                                 "RTT") \
    X(rtt_no_data,          "暂无数据",                            "No data") \
    X(rtt_value_fmt,        "%llu ms",                             "%llu ms")                       /* new */ \
    X(rtt_tip_fmt,          "BM 往返时延\n最近 %llu ms · 最小 %llu ms · 平均 %.0f ms · 最大 %llu ms\n样本 %llu 个", \
                            "BM round-trip time\nLast %llu ms · min %llu ms · avg %.0f ms · max %llu ms\n%llu samples") /* new */ \
    X(rtt_tip_none,         "BM 往返时延：暂无样本。",             "BM round-trip time: no samples yet.") /* new */ \
    X(loss,                 "丢包",                                "Loss")                          /* new */ \
    X(loss_value_fmt,       "%.1f%%",                              "%.1f%%")                        /* new */ \
    X(loss_tip_session_fmt, "本次 BM 会话：缺失 %llu / 应收 %llu 帧（%.2f%%）", \
                            "This BM session: %llu missing of %llu expected frames (%.2f%%)") /* new */ \
    X(loss_tip_session_none,"本次 BM 会话：暂无语音帧统计。",      "This BM session: no voice frame statistics yet.") /* new */ \
    X(loss_tip_call_fmt,    "当前通话：缺失 %llu / 应收 %llu 帧（%.2f%%）", \
                            "Current call: %llu missing of %llu expected frames (%.2f%%)") /* new */ \
    X(loss_tip_call_none,   "当前通话：暂无统计。",                "Current call: no statistics yet.") /* new */ \
    X(core,                 "核心",                                "Core")                          /* new */ \
    X(language_english,     "English",                             "English") \
    X(language_chinese,     "中文",                                 "Chinese") \
    X(relay_enable,         "启用中继",                            "Enable relay")                   /* new */ \
    X(relay_disable,        "停用中继",                            "Disable relay")                  /* new */ \
    X(relay_state_unknown,  "中继状态未知",                        "Relay status: unknown")          /* new */ \
    X(relay_tip_off,        "开启后连接电台使用 AP PC 模式 Y 模板（offset 0x05 = '1'）；需重新连接电台后生效。", \
                            "When on, the radio connects with the AP PC mode Y template (offset 0x05 = '1'); reconnect the radio to apply.") /* new */ \
    X(relay_tip_on,         "中继已开启：连接电台使用 AP PC 模式 Y 模板。点击停用。", \
                            "Relay is on: the radio connects with the AP PC mode Y template. Click to disable.") /* new */ \
    X(relay_fm,             "FM",                                  "FM")                             /* new */ \
    X(relay_fm_tip,         "FM 中继（官方未支持）：通过 CAT 静噪检测触发，使用当前 PTT 目标发往 BM。", \
                            "FM relay (not officially supported): triggered by CAT squelch detection, sent to BM on the current TX target.") /* new */ \
    X(relay_c4fm_unsupported,"C4FM 中继尚未支持，当前仅 FM 可用", "C4FM relay is not supported yet; only FM is available") /* new */ \
    X(relay_reconnect_needed,"中继设置已保存；需重新连接电台后生效。", \
                            "Relay setting saved; reconnect the radio to apply it.") /* new */ \
    X(relay_status_active,  "FM 中继进行中",                       "FM relay active")                /* new */ \
    X(relay_status_waiting, "等待静噪开启",                        "Waiting for squelch")            /* new */ \
    X(relay_status_no_cat,  "CAT 未连接",                          "CAT not connected")              /* new */ \
    X(op_relay_fm,          "FM 中继",                             "FM relay")                       /* new */ \
    X(relay_fm_rejected_fmt,"FM 中继未开始：%s",                   "FM relay not started: %s")       /* new */ \
    X(relay_history_group_fmt,"%s · FM 中继 → TG %u · TS%d · %.1f s · S 峰值 %s", \
                            "%s · FM relay → TG %u · TS%d · %.1f s · S peak %s") /* new */ \
    X(relay_history_private_fmt,"%s · FM 中继 → 私呼 %u · TS%d · %.1f s · S 峰值 %s", \
                            "%s · FM relay → private %u · TS%d · %.1f s · S peak %s") /* new */ \
    X(relay_history_tip,    "FM 中继记录（无呼号）。结束原因：%s", "FM relay record (no callsign). End reason: %s") /* new */ \
    X(log_error,            "错误",                                "Error")                          /* new */ \
    X(log_events,           "连接日志",                            "Connection log")                 /* new */ \
    X(log_empty,            "暂无连接事件。",                      "No connection events.")          /* new */ \
    X(log_clear,            "清空",                                "Clear")                          /* new */ \
    X(log_resolved,         "已恢复",                              "Resolved")                       /* new */ \
    X(log_radio_open,       "HRI 串口已打开，等待设备就绪。",      "HRI serial opened; waiting for device readiness.") /* new */ \
    X(log_radio_ready,      "HRI 电台已就绪。",                    "HRI radio is ready.")            /* new */ \
    X(log_radio_disconnected,"HRI 电台已断开。",                   "HRI radio disconnected.")       /* new */ \
    X(log_bm_connect_requested,"已请求连接 BM。",                  "BM connection requested.")       /* new */ \
    X(log_bm_disconnect_requested,"已请求断开 BM。",               "BM disconnect requested.")       /* new */ \
    X(log_cat_connected,    "CAT 已连接。",                        "CAT connected.")                 /* new */ \
    X(log_cat_disconnected, "CAT 已断开。",                        "CAT disconnected.")              /* new */ \
    X(log_core_ready,       "核心已就绪。",                        "Core is ready.")                 /* new */ \
    X(log_settings_saved,   "配置已保存。",                        "Settings saved.")                /* new */ \
    X(log_audio_changed,    "音频设备已切换。",                    "Audio devices changed.")         /* new */ \
    X(bm_error_fmt,         "BM 连接失败：%s",                     "BM connection failed: %s")       /* new */ \
    X(radio_error_fmt,      "电台连接失败：%s",                    "Radio connection failed: %s")    /* new */ \
    X(cat_error_fmt,        "CAT 连接失败：%s",                    "CAT connection failed: %s")      /* new */ \
    X(core_error_fmt,       "核心错误：%s",                        "Core error: %s")                 /* new */ \
    X(engine_stopped_banner_fmt,"核心已停止，所有连接已断开；点“连接电台”重新启动。（%s）", \
                            "Core stopped and all links are down. Click Connect to restart. (%s)") /* new */ \
    X(err_core_waveout,     "电台音频输出（WaveOut）故障导致核心停止；请检查 USB 声卡后重新连接。", \
                            "A radio audio output (WaveOut) fault stopped the core. Check the USB audio device and reconnect.") /* new */ \
    X(err_radio_waveout_unavailable,"电台音频输出暂不可用，正在自动重试；本通来话已拒绝。", \
                            "Radio audio output is temporarily unavailable and is being retried; this call was rejected.") /* new */ \
    X(bm_config_changed_while_connecting,"BM 连接已启用或正在进行；请先断开 BM，再保存账户配置。", \
                            "BM is connected or a connection attempt is in progress. Disconnect BM before saving account settings.") /* new */ \
    X(bm_config_saved_during_connection,"连接期间 BM 配置已更改；本次不会连接旧配置，请再次连接 BM。", \
                            "BM settings changed during connection. The old profile will not be used; connect BM again.") /* new */ \
    X(err_radio_selection,  "未能选择电台设备；请检查 HRI 串口和音频输入/输出设备后重试。", \
                            "Could not select radio devices. Check the HRI port and audio input/output, then retry.") /* new */ \
    X(err_radio_template,   "电台协议模板无效或缺失；请检查程序文件后重试。", \
                            "The radio protocol template is missing or invalid. Check the application files and retry.") /* new */ \
    X(err_radio_serial,     "无法打开或配置 HRI 串口；请检查电台连接及串口占用后重试。", \
                            "Could not open or configure the HRI port. Check the radio connection and whether another app is using the port, then retry.") /* new */ \
    X(err_radio_resources,  "无法分配电台连接资源；请重启应用后重试。", \
                            "Could not allocate radio connection resources. Restart the application and retry.") /* new */ \
    X(err_hri_version_timeout,"电台未在等待时间内返回 HRI 版本信息；请检查 USB/串口连接后重试。", \
                            "The radio did not return its HRI version in time. Check the USB/serial connection and retry.") /* new */ \
    X(err_hri_version_mismatch,"HRI 协议版本与程序不匹配；请确认电台固件和程序版本后重试。", \
                            "The HRI protocol version does not match this application. Check the radio firmware and application versions.") /* new */ \
    X(err_hri_malformed_record,"电台返回的数据格式无效；请重新连接电台后重试。", \
                            "The radio returned an invalid HRI data record. Reconnect the radio and retry.") /* new */ \
    X(err_hri_y_ack_timeout,"电台未确认 HRI 初始化；请检查连接状态后重试。", \
                            "The radio did not acknowledge HRI initialization. Check the connection and retry.") /* new */ \
    X(err_bm_password,      "BM 密码未填写；请完成 BM 账户配置并保存。", \
                            "BM password is missing. Complete and save the BM account settings.") /* new */ \
    X(err_bm_profile,       "BM 账户或服务器配置无效；请检查呼号、ID 和服务器设置。", \
                            "BM account or server settings are invalid. Check the callsign, ID, and server settings.") /* new */ \
    X(err_bm_dns,           "无法解析 BM 服务器地址；请检查服务器地址和网络连接。", \
                            "Could not resolve the BM server address. Check the server address and network connection.") /* new */ \
    X(err_bm_dns_timeout,   "解析 BM 服务器地址超时；请检查 DNS 和网络后重试。", \
                            "BM server address lookup timed out. Check DNS and the network, then retry.") /* new */ \
    X(err_bm_cancel_timeout,"取消 BM 服务器地址解析超时；请稍候后重试。", \
                            "Cancelling the BM server lookup timed out. Wait briefly and retry.") /* new */ \
    X(err_bm_transport,     "无法连接 BM 服务器；请检查服务器地址、UDP 端口和网络。", \
                            "Could not connect to the BM server. Check the server address, UDP port, and network.") /* new */ \
    X(err_bm_cleanup,       "BM 断开后的音频清理未完成；请检查音频设备后重试。", \
                            "Audio cleanup after BM disconnect did not finish. Check the audio devices and retry.") /* new */ \
    X(err_bm_rejected,      "BM 服务器拒绝登录；请检查呼号、DMR ID 和密码。", \
                            "The BM server rejected the login. Check the callsign, DMR ID, and password.") /* new */ \
    X(err_bm_session,       "BM 会话失败；请检查登录信息和网络后重试。", \
                            "The BM session failed. Check the login details and network, then retry.") /* new */ \
    X(err_quick_call_partial,"本机 Quick Call 只发送了部分内容；请检查电台连接后重试。", \
                            "The local Quick Call was only partially sent. Check the radio connection and retry.") /* new */ \
    X(manual_dmr_id,        "BM DMR ID（手动）",                    "BM DMR ID (manual)")             /* new */ \
    X(manual_dmr_id_hint,   "请手动填写 DMR ID。",                 "Enter the DMR ID manually.")     /* new */ \
    X(status,               "状态",                                "Status") \
    X(status_serial,        "串口",                                "Serial") \
    X(status_hri,           "HRI",                                 "HRI") \
    X(status_cat,           "CAT",                                 "CAT") \
    X(status_wave_in,       "音频输入",                            "Audio in") \
    X(status_wave_out,      "音频输出",                            "Audio out") \
    X(status_bm,            "BM",                                  "BM") \
    X(radio_link,           "电台 + CAT",                         "Radio + CAT") \
    X(radio_link_hint,      "此按钮同时连接或断开 HRI 电台串口与 CAT 串口。", \
                            "This button connects or disconnects both HRI radio and CAT serial ports.") \
    X(phase_stopped,        "未启动",                              "Not started") \
    X(phase_starting,       "准备中",                              "Preparing") \
    X(phase_running,        "HRI 就绪",                            "HRI ready") \
    X(phase_stopping,       "正在断开",                            "Disconnecting") \
    X(phase_failed,         "核心异常",                            "Core failed")                   /* new */ \
    X(phase_short_stopped,  "未启动",                              "Stopped") \
    X(phase_short_starting, "准备中",                             "Starting") \
    X(phase_short_running,  "已就绪",                              "Ready") \
    X(phase_short_stopping, "断开中",                              "Stopping") \
    X(phase_short_failed,   "异常",                                "Failed") \
    X(hri_waiting,          "HRI 串口已打开，等待设备就绪",        "HRI serial port opened; waiting for the device") \
    X(stop_exit,            "停止并退出",                          "Stop and exit") \
    X(group,                "组呼",                                "Group") \
    X(private_call,         "单呼",                                "Private") \
    X(channel_worldwide,    "全球",                                "World-wide") /* new */ \
    X(channel_china,        "全国",                                "China") /* new */ \
    X(channel_china_parrot, "中国鹦鹉",                            "China Parrot") /* new */ \
    X(channel_bm_parrot,    "BM 鹦鹉（私呼 9990）",                "BM Parrot (Private 9990)") /* new */ \
    X(static_group,         "静态组",                              "Static") \
    X(dynamic_group,        "动态组",                              "Dynamic") \
    X(btn_tx_target,        "呼叫目标",                            "TX target") \
    X(btn_set_tx,           "设为呼叫",                            "Set TX") \
    X(btn_remove,           "取消监听",                            "Remove") \
    X(btn_mute,             "临时屏蔽",                            "Mute") \
    X(btn_unmute,           "恢复收听",                            "Unmute") \
    X(btn_join,             "激活组",                              "Join") \
    X(btn_rejoin,           "再次激活",                            "Rejoin") \
    X(btn_joining,          "请求处理中",                          "Joining…") \
    X(btn_set_tx_short,     "设为PTT",                             "Set TX") \
    X(btn_tx_target_short,  "PTT目标",                             "TX target") \
    X(btn_remove_short,     "移除",                                "Remove") \
    X(btn_mute_short,       "屏蔽",                                "Mute") \
    X(btn_unmute_short,     "恢复",                                "Unmute") \
    X(btn_join_short,       "激活",                                "Join") \
    X(btn_rejoin_short,     "再激活",                              "Rejoin") \
    X(btn_joining_short,    "处理中",                              "Working…") \
    X(tip_tx_selected,      "已选为下次 PTT 呼叫目标",             "Selected as the next TX target") \
    X(tip_set_tx,           "选择此频道作为下次 PTT 目标",         "Select this channel as the next TX target") \
    X(tip_quick_call,       "请求本机加入该动态组，并等待本机发送结果。", \
                            "Ask the local node to join this dynamic group and wait for its send result.") \
    X(tip_quick_pending,    "一项激活请求正在等待本机结果；结果返回或等待超时后可再次操作。", \
                            "An activation request is waiting for a local result. Try again after a result or timeout.") \
    X(tip_static,           "TG %u TS%d；静态组已读取。",          "TG %u TS%d; static group read back.")   /* new */ \
    X(tip_dynamic_sent,     "TG %u TS%d；已发送激活请求。",        "TG %u TS%d; activation request sent.") /* new */ \
    X(empty_channels,       "暂无频道；在“日常控制”中加入监听。",  "No channels yet. Add one under Daily controls.") /* new */ \
    X(current_call,         "当前来话",                            "Current call")                  /* new */ \
    X(recent_calls,         "最近来话",                            "Recent calls")                  /* new */ \
    X(no_call,              "暂无来话",                            "No call")                       /* new */ \
    X(call_history,         "来话历史",                            "Call history") \
    X(set_history_target,   "设为PTT目标",                         "Set TX target") \
    X(tip_history_target,   "仅当该ID和类型已经在频道列表中时，才能设为PTT目标。", \
                            "The ID and type must already be in the channel list to set it as the TX target.") \
    X(history_group,        "%s · 组呼 TG %u · 来自 %s",           "%s · Group call TG %u · from %s") \
    X(history_private,      "%s · 单呼本机 DMR ID %u · 来自 %s",   "%s · Private call to local DMR ID %u · from %s") \
    X(call_target_group,    "组呼 TG %u · TS%d",                   "Group TG %u · TS%d")            /* new */ \
    X(call_target_private,  "单呼 · TS%d",                         "Private · TS%d")                /* new */ \
    X(rx_live_peak,         "实时接收峰值",                        "Live RX peak")                 /* new */ \
    X(tx_live_peak,         "实时发送峰值",                        "Live TX peak")                 /* new */ \
    X(daily_controls,       "日常控制",                            "Daily controls") \
    X(radio_control,        "电台控制",                            "Radio control")                 /* new */ \
    X(cat_port,             "CAT 串口",                            "CAT port") \
    X(baud_rate,            "波特率",                              "Baud rate") \
    X(main_mode,            "MAIN 模式",                           "MAIN mode") \
    X(frequency_mhz,        "频率 MHz",                            "Frequency MHz") \
    X(power_w,              "功率 W",                              "Power W") \
    X(apply,                "应用",                                "Apply") \
    X(add_channel_id,       "增加动态组 频道ID",                   "Add group or private ID") \
    X(type,                 "类型",                                "Type") \
    X(select,               "请选择",                              "Select") \
    X(add_listen,           "加入监听",                            "Add to listening") \
    X(volume,               "音量",                                "Audio") \
    X(playback_gain,        "播放增益",                            "Playback gain") \
    X(transmit_gain,        "发送增益",                            "Transmit gain") \
    X(wiresx_port,          "Wires-X 串口",                        "Wires-X port") \
    X(connect_serial,       "连接",                                "Connect") \
    X(disconnect_serial,    "断开",                                "Disconnect") \
    X(connecting_radio,     "连接中…",                            "Connecting…") \
    X(disconnecting_serial, "断开中…",                            "Disconnecting…") \
    X(connect_bm,           "连接BM",                              "Connect BM") \
    X(disconnect_bm,        "断开BM",                              "Disconnect BM") \
    X(connecting_bm,        "正在连接BM",                          "Connecting…") \
    X(disconnecting_bm,     "正在断开BM",                          "Disconnecting…") \
    X(callsign,             "呼号",                                "Callsign") \
    X(bm_account,           "BrandMeister 配置",                  "BrandMeister settings") \
    X(bm_changes_next_connection,"保存后在下次连接 BM 时应用；DMR ID 必须手动填写。", \
                            "Saved values apply the next time BM connects. Enter the DMR ID manually.") \
    X(bm_save_before_connect,"先保存 BrandMeister 配置后再连接。", "Save BrandMeister settings before connecting.") \
    X(dmr_id,               "DMR ID",                              "DMR ID") \
    X(device_no,            "设备编号",                            "Device no.") \
    X(bm_server,            "BM 服务器",                           "BM server") \
    X(custom,               "自定义",                              "Custom") \
    X(udp_port,             "UDP 端口",                            "UDP port") \
    X(host_ipv4,            "主机名 / IPv4",                       "Host / IPv4") \
    X(bm_password,          "BM 密码",                             "BM password") \
    X(bm_api_key,           "BM API Key",                          "BM API Key") \
    X(audio_devices,        "音频设备",                            "Audio devices") \
    X(audio_devices_switching,"正在切换音频设备…",                "Switching audio devices…") \
    X(audio_devices_applied,"音频设备已切换。",                   "Audio devices switched.") \
    X(audio_devices_failed, "音频设备切换失败，请检查设备后重试。", "Audio device switch failed. Check devices and retry.") \
    X(audio_devices_next_connection,"下次连接时使用所选设备。",    "Selected devices will be used on the next connection.") \
    X(local_playback,       "电脑播放",                           "PC playback")                     /* new */ \
    X(local_audio_route_status,"音频路由",                        "Audio route")                    /* new */ \
    X(local_playback_inactive,"未启用",                            "Inactive")                        /* new */ \
    X(local_playback_ready, "就绪",                                "Ready")                           /* new */ \
    X(local_playback_playing,"播放中",                             "Playing")                         /* new */ \
    X(local_playback_unavailable,"不可用",                         "Unavailable")                    /* new */ \
    X(local_playback_failed,"失败",                                "Failed")                          /* new */ \
    X(local_playback_route_radio,"电台音频",                       "Radio audio")                     /* new */ \
    X(local_playback_route_output,"电脑输出",                      "PC output")                       /* new */ \
    X(local_playback_route_silent,"未播放",                        "No playback")                    /* new */ \
    X(local_playback_error_selection,"未找到可用的电脑音频输出设备；请选择 WaveOut 设备。", \
                            "No usable PC audio output was found. Select a WaveOut device.") /* new */ \
    X(local_playback_error_open,"无法打开电脑音频输出设备。",      "Could not open the PC audio output device.") /* new */ \
    X(local_playback_error_submit,"电脑音频数据提交失败。",        "Could not submit PC audio data.") /* new */ \
    X(local_playback_error_lost,"电脑音频设备已断开。",           "The PC audio device was disconnected.") /* new */ \
    X(local_playback_error_close,"无法关闭旧的电脑音频输出设备。", "Could not close the previous PC audio output device.") /* new */ \
    X(local_playback_switch_busy,"通话期间无法切换电脑音频输出；结束通话后重试。", \
                            "PC audio output cannot be changed during a call. Retry after the call ends.") /* new */ \
    X(input,                "输入",                                "Input") \
    X(output,               "输出",                                "Output") \
    X(refresh_devices,      "刷新设备",                            "Refresh devices") \
    X(save_settings,        "保存配置",                            "Save settings") \
    X(settings_saved,       "设置已保存。",                        "Settings saved.") \
    X(settings_save_failed, "配置保存失败：%s",                    "Could not save settings: %s")   /* new */ \
    X(password_empty,       "BM 密码未填写，未发起连接。",         "BM password is empty. No connection was started.") \
    X(channel_id_invalid,   "请输入 1 至 16777215 的频道 ID。",    "Enter a channel ID from 1 to 16777215.") /* new */ \
    X(channel_kind_needed,  "请选择频道类型。",                    "Select a channel type.")        /* new */ \
    X(channel_exists,       "该频道已在列表中。",                  "This channel is already in the list.") /* new */ \
    X(channel_not_ready,    "核心尚未准备好接收频道设置。",        "The core is not ready to receive channel settings.") \
    X(font_simhei,          "未找到等线，已改用黑体。",            "DengXian not found; using SimHei.") /* new */ \
    X(font_default,         "未找到可用中文字体，中文可能无法显示。", "No CJK font is available; Chinese text may not render.") /* new */ \
    X(fake_banner,          "模拟引擎",                            "Simulated engine")              /* new */ \
    X(engine_unavailable,   "真实引擎尚未接入；请使用 --fake 启动。", "The real engine is not wired yet; start with --fake.") /* new */ \
    X(op_start,             "连接串口",                            "Connect radio") \
    X(op_stop,              "断开串口",                            "Disconnect radio") \
    X(op_bm,                "BM 连接",                             "BM connection")                 /* new */ \
    X(op_rx_policy,         "监听频道",                            "Listening channels")            /* new */ \
    X(op_tx_policy,         "PTT 目标",                            "TX target")                     /* new */ \
    X(op_quick_call,        "激活组",                              "Join") \
    X(op_gains,             "音量",                                "Audio") \
    X(op_audio_devices,     "音频设备",                            "Audio devices")                 /* new */ \
    X(op_cat,               "CAT",                                 "CAT") \
    X(result_fmt,           "%s：%s",                              "%s: %s")                        /* new */ \
    X(result_fmt_detail,    "%s：%s（%s）",                        "%s: %s (%s)")                   /* new */ \
    X(st_accepted,          "已执行",                              "Done")                          /* new */ \
    X(st_idempotent,        "无变化",                              "No change")                     /* new */ \
    X(st_stale_revision,    "状态已变化，请重试",                  "State changed; try again")      /* new */ \
    X(st_busy,              "正忙",                                "Busy")                          /* new */ \
    X(st_not_ready,         "未就绪",                              "Not ready")                     /* new */ \
    X(st_invalid,           "参数无效",                            "Invalid")                       /* new */ \
    X(st_forbidden,         "不允许",                              "Not allowed")                   /* new */ \
    X(st_failed,            "失败",                                "Failed")                        /* new */ \
    X(st_no_result,         "无结果",                              "No result")                     /* new */ \
    X(tx_active_badge,      "发射中",                              "Transmitting")                  /* new */ \
    X(bm_static_groups,     "BM 静态组",                           "BM static groups")              /* new */ \
    X(static_device_fmt,    "设备 %u",                             "Device %u") \
    X(static_refresh,       "刷新",                                "Refresh") \
    X(static_remove,        "移除",                                "Remove") \
    X(static_add,           "添加为静态组",                        "Add static group") \
    X(static_need_key,      "需启用BM API key",                    "BM API key required") \
    X(static_empty,         "当前设备没有 BM 静态组。",            "No BM static groups for this device.") /* new */ \
    X(static_tg_hint,       "TG",                                  "TG") \
    X(static_row_fmt,       "TG %u · %s",                          "TG %u · %s")                    /* new */ \
    X(static_slot_fmt,      "TS%d",                                "TS%d")                          /* new */ \
    X(static_slot_dmo,      "DMO",                                 "DMO")                           /* new */ \
    X(static_imported_fmt,  "已把 %u 个 BM 静态组加入收听频道：TG %s。", \
                            "Added %u BM static groups to the listen channels: TG %s.") /* new */ \
    X(static_removing_fmt,  "正在从 BM 移除静态组 TG %u…",         "Removing static group TG %u from BM…") /* new */ \
    X(static_remove_failed_fmt,"BM 静态组 TG %u 移除失败，频道已保留：%s", \
                            "Could not remove static group TG %u from BM; the channel was kept: %s") /* new */ \
    X(static_removed_unlisten_fmt,"已从 BM 移除静态组 TG %u，并取消收听。", \
                            "Removed static group TG %u from BM and stopped listening.") /* new */ \
    X(static_unlisten_no_key_fmt,"已取消收听 TG %u；未设置 API Key，BM 静态组未改动。", \
                            "Stopped listening to TG %u; no API key is set, so the BM static group was not changed.") /* new */ \
    X(static_remove_title,  "移除静态组",                          "Remove static group")           /* new */ \
    X(static_remove_ask_fmt,"同时从 BM 移除静态组 TG %u？",        "Also remove static group TG %u from BM?") /* new */ \
    X(static_remove_no_key, "未设置 API Key：只能取消收听，BM 静态组不会改动。", \
                            "No API key is set: only listening stops; the BM static group is not changed.") /* new */ \
    X(static_remove_both,   "从 BM 移除并取消收听",                "Remove from BM and stop listening") /* new */ \
    X(static_remove_listen_only,"仅取消收听",                      "Stop listening only")           /* new */ \
    X(btn_cancel,           "取消",                                "Cancel")                        /* new */ \
    X(status_local_playback_tip_fmt,"%s：%s",                      "%s: %s")                        /* new */ \
    X(channel_idle,         "空闲",                                "Idle")                          /* new */ \
    X(last_call_fmt,        "上次 %s",                             "Last %s")                       /* new */ \
    X(auto_select,          "自动",                                "Auto")                          /* new */ \
    X(device_resolved,      "已解析",                              "Resolved") \
    X(device_ambiguous,     "有多个候选",                          "Multiple matches") \
    X(device_missing,       "未找到设备",                          "Device not found") \
    X(device_conflict,      "设备冲突",                            "Device conflict") \
    X(device_unavailable,   "不可用",                              "Unavailable") \
    X(device_manual_unclassified,"手动设备未分类",                  "Manual device is unclassified") \
    X(device_active_missing,"正在使用，但不在设备列表",            "Active, but missing from the device list") \
    X(device_active,        "正在使用",                            "Active") \
    X(unknown,              "未知",                                "Unknown") \
    X(op_auto_quick_call,   "启动自动组呼",                        "Startup group Quick Call")        /* new */ \
    X(startup_group_waiting_fmt, \
                            "自动组呼已冻结 %u 个目标，等待 BM 首次连接；忽略私呼 %u 个、TG4000 安全跳过 %u 个、重复合并 %u 个、无效跳过 %u 个、静态组无需激活 %u 个。", \
                            "Startup group Quick Calls frozen: %u targets waiting for the first BM connection; ignored %u private calls, safety-skipped %u TG4000 entries, merged %u duplicates, skipped %u invalid targets, and %u static groups need no activation.") /* new */ \
    X(startup_group_connected_fmt, \
                            "BM 已连接；开始依序在本机发送 %u 个已保存组呼目标。", \
                            "BM connected; starting local Quick Call sends for %u saved group targets in order.") /* new */ \
    X(startup_group_paused_fmt, \
                            "BM 已断开；自动组呼暂停，待处理 %u 个目标。本机已发送 %u 个，失败 %u 个。", \
                            "BM disconnected; startup group calls paused with %u targets pending. %u sent locally, %u failed.") /* new */ \
    X(startup_group_resumed_fmt, \
                            "BM 已重连；继续处理剩余 %u 个组呼目标。", \
                            "BM reconnected; resuming the remaining %u group targets.") /* new */ \
    X(startup_group_busy, \
                            "BM 媒体忙；等待空闲，持续忙碌 30 秒后跳过未处理目标。", \
                            "BM media is busy; waiting for idle. Remaining targets are skipped after 30 seconds of continuous busy state.") /* new */ \
    X(startup_group_progress_fmt, \
                            "自动组呼进度：本机已发送 %u/%u 个，失败 %u 个，剩余 %u 个。", \
                            "Startup group Quick Calls: %u/%u sent locally, %u failed, %u remaining.") /* new */ \
    X(startup_group_done_fmt, \
                            "自动组呼完成：本机已发送 %u/%u 个，失败 %u 个，持续忙碌跳过 %u 个；忽略私呼 %u 个、TG4000 安全跳过 %u 个、重复合并 %u 个、无效跳过 %u 个、静态组无需激活 %u 个。", \
                            "Startup group Quick Calls complete: %u/%u sent locally, %u failed, %u skipped after persistent busy; ignored %u private calls, safety-skipped %u TG4000 entries, merged %u duplicates, skipped %u invalid targets, and %u static groups need no activation.") /* new */ \
    X(startup_group_sent_fmt, \
                            "TG %u TS%d：Quick Call 两帧已由本机发送。", \
                            "TG %u TS%d: both Quick Call frames were sent locally.") /* new */ \
    X(startup_group_failure_fmt, \
                            "TG %u TS%d：本机 Quick Call 失败（%s）。", \
                            "TG %u TS%d: local Quick Call failed (%s).") /* new */ \
    X(muted_badge,          "已屏蔽",                              "Muted")                         /* new */ \
    X(filtered_group_fmt,   "BM 有未收听的组呼：TG %u（TS%d）· 发起 %u · %u 秒前", \
                            "Unheard BM group call: TG %u (TS%d) · from %u · %us ago") /* new */ \
    X(filtered_private_fmt, "BM 有未收听的私呼：%u → %s（TS%d）· %u 秒前", \
                            "Unheard BM private call: %u → %s (TS%d) · %us ago") /* new */ \
    X(filtered_local_dst,   "本机",                                "this radio")                    /* new */ \
    X(filtered_join,        "加入收听",                            "Listen")                        /* new */ \
    X(tip_filtered_join,    "把该 TG/时隙加入频道列表并开始收听。\nBM 只转发本机在服务器上静态订阅或动态激活的 TG。", \
                            "Add this TG/slot to the channel list and start listening.\nBM only forwards TGs statically subscribed or dynamically activated for this hotspot.") /* new */ \
    X(tip_filtered_private_join, "把该私呼对端加入私呼频道并开始收听。\n该呼叫的目标是本机 DMR ID。", \
                            "Add this private-call peer as a private channel and start listening.\nThe call was addressed to this radio's DMR ID.") /* new */ \
    X(tip_filtered_private_info, "该私呼的目标不是本机 DMR ID，仅供提示；加入该对端也不会收到此呼叫。", \
                            "This private call is not addressed to this radio; it is shown for information only.") /* new */ \
    /* ---------- R131：频道状态机 / BM 冷却 / 端点音量 / CAT 门控（独立块，追加在末尾） ---------- */ \
    X(op_muted_groups,      "静音频道",                            "Muted channels")                /* new */ \
    X(op_disconnect_dynamic,"停用动态组",                          "Disable dynamic group")         /* new */ \
    X(ch_badge_static,      "静态组",                              "Static")                        /* new */ \
    X(ch_badge_muted,       "静音",                                "Muted")                         /* new */ \
    X(ch_badge_dyn_active,  "动态·已激活",                         "Dynamic · active")              /* new */ \
    X(ch_badge_dyn_inactive,"动态·未激活",                         "Dynamic · inactive")            /* new */ \
    X(ch_badge_disabled,    "已停用",                              "Disabled")                      /* new */ \
    X(ch_btn_mute,          "静音",                                "Mute")                          /* new */ \
    X(ch_btn_unmute,        "取消静音",                            "Unmute")                        /* new */ \
    X(ch_btn_disable,       "停用",                                "Disable")                       /* new */ \
    X(ch_btn_enable,        "启用",                                "Enable")                        /* new */ \
    X(ch_btn_working,       "处理中",                              "Working…")                      /* new */ \
    X(ch_tip_mute,          "静音：照常接收并显示来话，只是本机和电台扬声器都不出声。\n注意：BM 单时隙热点上静态组仍会占用时隙，这是 BM 侧限制。", \
                            "Mute: calls are still received and shown, but neither the PC nor the radio speaker plays them.\nNote: on a single-slot BM hotspot a static group still occupies the slot (a BM limitation).") /* new */ \
    X(ch_tip_unmute,        "取消静音：恢复播放该静态组的来话。", "Unmute: play calls on this static group again.") /* new */ \
    X(ch_tip_disable,       "停用：不再收听该组，并向 BM 发送 TG4000 断开该时隙的动态组。", \
                            "Disable: stop listening and send TG4000 to BM to drop dynamic groups on this slot.") /* new */ \
    X(ch_tip_disable_listen,"停用：不再收听该频道（只改本机收听策略）。", \
                            "Disable: stop listening on this channel (local receive policy only).") /* new */ \
    X(ch_tip_enable,        "启用：恢复收听，并向 BM 发送 Quick Call 激活该动态组。", \
                            "Enable: listen again and send a Quick Call to BM to activate this dynamic group.") /* new */ \
    X(ch_tip_enable_listen, "启用：恢复收听该频道。",              "Enable: listen on this channel again.") /* new */ \
    X(ch_tip_need_bm,       "需要 BM 已连接才能激活动态组。",      "BM must be connected to activate a dynamic group.") /* new */ \
    X(ch_tip_dynamic_inactive_fmt, "TG %u TS%d；本次运行尚未激活，点击“启用”发送 Quick Call。", \
                            "TG %u TS%d; not activated in this session. Click Enable to send a Quick Call.") /* new */ \
    X(ch_tip_disabled,      "已停用：不在收听策略中，来话会被过滤。", \
                            "Disabled: not in the receive policy; its calls are filtered.") /* new */ \
    X(ch_disabled_offline_fmt, "TG %u 已停用；BM 未连接，未发送 TG4000。", \
                            "TG %u disabled; BM is not connected, so TG4000 was not sent.") /* new */ \
    X(ch_disabled_tg4000_fmt,  "TG %u 已停用；已由本机向 BM 发送 TG4000（TS%d）。", \
                            "TG %u disabled; TG4000 (TS%d) was sent to BM locally.") /* new */ \
    X(bm_cooldown_fmt,      "连接BM (%us)",                        "Connect (%us)")                 /* new */ \
    X(bm_cooldown_tip,      "刚断开 BM：等待服务器释放上次会话后再连接。", \
                            "BM was just disconnected; waiting for the server to release the previous session.") /* new */ \
    X(bm_stale_retry_fmt,   "服务器尚未释放上次会话，%u 秒后自动重试", \
                            "Server has not released the previous session; retrying in %u s") /* new */ \
    X(bm_stale_retrying,    "服务器尚未释放上次会话，正在自动重试", \
                            "Server has not released the previous session; retrying now") /* new */ \
    X(bm_waiting_release,   "等待释放",                            "Waiting")                       /* new */ \
    X(volume_playback,      "播放音量（Windows）",                 "Playback volume (Windows)")     /* new */ \
    X(volume_transmit,      "发送音量（Windows 录音）",            "Transmit volume (Windows input)") /* new */ \
    X(volume_unknown,       "—",                                   "—")                             /* new */ \
    X(volume_tip_playback,  "直接调节所选播放设备（WaveOut）的 Windows 音量；在 Windows 设置中调整会同步到这里。", \
                            "Sets the Windows volume of the selected playback device (WaveOut); changes made in Windows settings are mirrored here.") /* new */ \
    X(volume_tip_transmit,  "直接调节所选录音设备（WaveIn，USB Audio Mic）的 Windows 音量；实测约 70% 时对方听感合适。", \
                            "Sets the Windows volume of the selected recording device (WaveIn, USB Audio Mic); about 70% sounded right in field tests.") /* new */ \
    X(volume_no_device,     "未选择唯一的音频设备",                "No unique audio device selected") /* new */ \
    X(volume_set_failed_fmt,"设置 Windows 音量失败：%s",           "Failed to set Windows volume: %s") /* new */ \
    X(advanced_gain,        "高级：数字增益（默认 1×）",           "Advanced: digital gain (default 1×)") /* new */ \
    X(advanced_gain_tip,    "软件内部的额外数字增益，只在本次运行生效；正常情况下保持 1×，用上面的 Windows 音量调节。", \
                            "Extra in-app digital gain for this session only. Normally keep 1× and use the Windows volume above.") /* new */ \
    X(meter_dbfs_tip,       "峰值电平（dBFS，最近 200 ms 峰值）。虚线为 -18 dBFS 参考（常用的平均电平参考）；语音峰值通常比平均高 9–12 dB，实测对方听感合适时峰值约 -9 dBFS。", \
                            "Peak level (dBFS, 200 ms peak). The dashed line marks the common -18 dBFS average reference; speech peaks run 9-12 dB above average, and the level reported to sound right peaked near -9 dBFS.") /* new */ \
    X(cat_deferred_tx,      "正在发射，设置未发送；草稿已保留，发射结束后自动应用。", \
                            "Transmitting; the setting was not sent. Your draft is kept and will be applied after TX ends.") /* new */ \
    X(cat_deferred_hri,     "HRI 正在向电台播放来话，改频率/模式会打断 RF；草稿已保留，来话结束后自动应用。", \
                            "HRI is playing a call through the radio; changing frequency/mode would interrupt RF. Your draft is kept and will be applied after the call.") /* new */

// R131 引擎侧修复新增文案（独立块，减少与界面改动的合并冲突）。枚举与文案表在主表之后展开本块。
#define WIREX_GUI_STRINGS_R131(X) \
    X(hri_lost_fmt,         "HRI 连接中断（%s），正在自动重连…", \
                            "HRI link lost (%s); reconnecting automatically…") /* new */ \
    X(hri_restored,         "HRI 已自动重连。",                    "HRI reconnected automatically.") /* new */

#define WIREX_GUI_STRINGS_HRI_POWER(X) \
    X(hri_power_tooltip, "HRI 模式下功率由本软件通过 Y 记录下发（每秒一次）", \
                         "In HRI mode, this application sends power via a Y record once per second.") \
    X(hri_power_not_retained, "电台未保持设定功率", "The radio did not retain the requested power.") \
    X(hri_power_link_lost, "HRI 已断开，功率设置未确认。", "HRI disconnected before the power setting was confirmed.") \
    X(hri_power_query_unavailable, "无法确认电台功率：CAT 查询不可用。", "Cannot confirm radio power: CAT query is unavailable.")
#define WIREX_GUI_STRINGS_R133(X) \
    X(hri_channel_tooltip, "HRI 模式下频率/调制由本软件通过 Y 记录下发（每秒一次）", "In HRI mode, frequency and modulation are sent by this software through Y records once per second.") \
    X(hri_frequency_invalid, "频率需在 144–148 / 430–440 MHz，精度 1 kHz", "Frequency must be 144–148 or 430–440 MHz, in 1 kHz steps.") \
    X(hri_channel_not_retained, "电台未保持设定频率/模式", "The radio did not retain the requested frequency or mode.") \
    X(hri_y_deferred, "HRI 正在播放来话，设定已延后，将在来话结束后生效。", "The setting is deferred until HRI playback ends.") \
    X(hri_c4fm_voice_warning, "C4FM 数字模式：手咪上行与 FM 中继暂不支持，仅用于试验", "C4FM digital: mic uplink and FM relay are not supported yet (experimental)") \
    X(hri_c4fm_voice_short, "! PC 语音不支持", "! No PC voice")

// quick-call deferral: kept separate to ease concurrent string-table merges.
#define WIREX_GUI_STRINGS_QUICK_CALL_DEFERRAL(X) \
    X(quick_call_deferred, "来话结束后执行。", "Will run after the current call.")

// radio/BM decoupling: BM 未配置时电台独立可用；BM 连接需完整登录字段（API Key 可选）。
#define WIREX_GUI_STRINGS_RADIO_BM_DECOUPLING(X) \
    X(bm_not_configured, "BM 未配置：填写呼号、DMR ID、密码后可连接 BM", \
                          "BM not configured: enter callsign, DMR ID and password to connect BM") \
    X(bm_connect_disabled_tip, "BM 设置不完整：填写呼号、DMR ID、密码并保存后可连接 BM", \
                               "BM settings incomplete: enter callsign, DMR ID and password, then save, to connect BM") \
    X(radio_bm_independent, "电台连接与 BM 相互独立；BM 未配置不影响电台使用。", \
                            "Radio and BM connect independently; an unconfigured BM does not affect the radio.")

// R135 version/update：标题栏版本标签（更新提示）的 tooltip。独立块，追加在末尾。
#define WIREX_GUI_STRINGS_R135(X) \
    X(update_tip_unknown,   "尚未检查更新；点击打开发布页",        "Update not checked yet; click to open the releases page") /* new */ \
    X(update_tip_checking,  "正在检查更新…",                       "Checking for updates…")          /* new */ \
    X(update_tip_up_to_date,"已是最新版本",                        "You have the latest version")    /* new */ \
    X(update_tip_failed,    "未能检查更新；点击打开发布页",        "Could not check for updates; click to open the releases page") /* new */ \
    X(update_tip_available_fmt, "有新版本 %s，点击打开发布页",     "New version %s is available; click to open the releases page") /* new */

// R136 history/channels：来话历史改为“向来源单呼”，以及新增动态组自动激活。
#define WIREX_GUI_STRINGS_R136(X) \
    X(set_history_private_target, "设为单呼目标",                  "Set private TX target") /* new */ \
    X(tip_history_private_target_fmt, "向 %s（%u）单呼",           "Private call to %s (%u)") /* new */ \
    X(tip_history_private_target_id_fmt, "向 %u 单呼",             "Private call to %u") /* new */ \
    X(tip_history_target_none, "选择一条来话记录后，可将其来源 DMR ID 设为单呼目标。", \
                            "Select a call record to target its source DMR ID as a private call.") /* new */
// R136 caller region
#define WIREX_GUI_STRINGS_R136_CALLER_REGION(X) \
    X(caller_region_tip_fmt, "国家/地区：%s",                        "Country/region: %s")             /* new */
// R136 title/links：BM 密码 / API Key 旁的“设置”链接。
#define WIREX_GUI_STRINGS_R136_TITLE_LINKS(X) \
    X(bm_link_setup,        "设置",                                "Set up")                         /* new */ \
    X(bm_link_setup_tip,    "打开 BrandMeister 自助服务页，设置账号密码", \
                            "Open the BrandMeister self-care page to set your account password") /* new */ \
    X(bm_link_api_key_tip,  "打开 BrandMeister API Key 页面，创建或查看 API Key", \
                            "Open the BrandMeister API Key page to create or view your API key") /* new */

// GUI ViewModel status, validation, and service errors.
#define WIREX_GUI_STRINGS_VIEW_MODEL(X) \
    X(err_unique_radio_devices, "未找到唯一可用的 HRI/USB Audio 设备。", "Could not resolve one usable HRI and USB audio device pair.") \
    X(err_runtime_config_service, "常驻引擎配置服务不可用。", "The engine configuration service is unavailable.") \
    X(err_bm_revision_connect, "BM 连接 revision 已达到上限，未发起连接。", "The BM connection revision limit was reached; no connection was started.") \
    X(err_bm_revision_switch, "BM 连接 revision 已达到上限，无法切换连接。", "The BM connection revision limit was reached; the connection could not be changed.") \
    X(err_bm_runtime_stopped, "BM runtime 尚未运行。", "The BM runtime is not running.") \
    X(err_audio_cleanup_warning, "新音频设备已生效，但旧设备报告了清理警告。", "The new audio device is active, but cleanup of the previous device reported a warning.") \
    X(err_bm_config_revision, "BM 配置版本已达到上限，无法安全保存。", "The BM configuration revision limit was reached; settings were not saved.") \
    X(err_radio_device_service, "电台设备解析服务不可用。", "The radio device resolver is unavailable.") \
    X(err_hri_audio_unresolved, "未解析到唯一可用的 HRI 串口和 USB Audio 输入/输出端点。", "Could not resolve a unique HRI port and USB audio input/output pair.") \
    X(err_desired_power_range, "期望功率必须为 5–50 W。", "Requested power must be between 5 and 50 W.") \
    X(err_bm_config_service, "BM 配置服务不可用。", "The BM configuration service is unavailable.") \
    X(static_busy, "BM 静态组操作正在进行。", "A BM static-group operation is already in progress.") \
    X(static_module_unavailable, "BM 静态组模块不可用。", "The BM static-group service is unavailable.") \
    X(static_identity_changed_keep_channel, "设备或 API Key 已变更；频道保留。", "The device or API key changed; the channel was kept.") \
    X(static_save_device_id, "请先保存有效的 BM 设备 ID。", "Save a valid BM device ID first.") \
    X(static_api_key_required, "请输入 BM API Key。", "Enter a BM API key.") \
    X(static_read_first, "请先读取当前设备的 BM 静态组。", "Read this device's BM static groups first.") \
    X(static_reading, "正在读取 BM 静态组。", "Reading BM static groups…") \
    X(static_identity_changed_hide_old, "设备或 API Key 已变更；未显示旧设备的 BM 静态组。", "The device or API key changed; static groups from the previous device are hidden.") \
    X(static_tg_invalid, "请输入 1 至 16777215 的静态组 ID。", "Enter a static-group ID from 1 to 16777215.") \
    X(static_slot_unavailable, "设备状态不可用；添加已禁用。", "The device status is unavailable; adding a static group is disabled.") \
    X(static_exists, "该静态组已存在。", "This static group already exists.") \
    X(static_adding, "正在向 BM 添加静态组。", "Adding the static group to BM…") \
    X(static_select_first, "请先选择当前设备的一条 BM 静态组。", "Select one of this device's BM static groups first.") \
    X(static_removing, "正在向 BM 移除静态组。", "Removing the static group from BM…") \
    X(static_key_or_id_changed, "设备或 API Key 已变更；请刷新 BM 静态组。", "The device or API key changed; refresh BM static groups.") \
    X(err_cat_config_revision, "CAT 配置版本已达到上限，无法安全保存。", "The CAT configuration revision limit was reached; settings were not saved.")

// GUI config/device-resolution messages; these can appear in tooltips and startup errors.
#define WIREX_GUI_STRINGS_CONFIG_BRIDGE(X) \
    X(cfg_device_number_required, "请填写两位设备编号（00–99），再保存本机 DMR ID。", "Enter a two-digit device number (00–99), then save the local DMR ID.") \
    X(cfg_hri_mode_invalid, "HRI 频率或调制模式无效。", "The HRI frequency or modulation mode is invalid.") \
    X(cfg_no_com_ports, "当前没有枚举到 Windows COM 端口。", "No Windows COM ports were found.") \
    X(cfg_no_hri_port, "当前没有识别到 HRI 串口；请检查连接并刷新设备列表。", "No HRI port was detected. Check the connection and refresh the device list.") \
    X(cfg_port_not_found_fmt, "所选串口 %s 当前没有枚举到。", "The selected serial port %s is not currently present.") \
    X(cfg_port_not_hri_fmt, "指定的串口 %s 不是当前识别到的 HRI 端口；请检查选择。", "Serial port %s is not the detected HRI port. Check the selection.") \
    X(cfg_auto_hri_failed, "无法自动选择 HRI COM 端口；请在主界面选择串口或检查 HRI 连接。", "Could not select an HRI COM port automatically. Choose a port on the main screen or check the HRI connection.") \
    X(cfg_waveout_not_unique, "WaveOut 输出设备没有唯一解析结果；请手动选择。", "Could not identify one WaveOut output device. Select it manually.") \
    X(cfg_selected_hri_fmt, "自动选择 HRI 串口 %s。", "Selected HRI port %s automatically.") \
    X(cfg_saved_hri_reused, "沿用已保存且当前识别为 HRI 的串口。", "Keeping the saved port, which is currently identified as HRI.") \
    X(cfg_duplicate_com, "系统返回重复的 COM 记录；请刷新设备列表后手动选择 HRI 串口。", "Windows returned duplicate COM port records. Refresh the device list and select the HRI port manually.") \
    X(cfg_serial_catalog_failed, "Windows 串口目录读取失败；请刷新设备列表后重试。", "Could not read the Windows serial-port list. Refresh the device list and retry.") \
    X(cfg_no_hri_detected, "当前串口目录没有识别到 HRI 设备。", "No HRI device was identified in the current serial-port list.") \
    X(cfg_multiple_hri, "发现多个 HRI 串口候选；请手动选择一个。", "Multiple HRI ports were found. Select one manually.") \
    X(cfg_saved_hri_missing_fmt, "已保存的 HRI 串口 %s 当前没有枚举到。", "The saved HRI port %s is not currently present.") \
    X(cfg_duplicate_hri, "系统返回重复的 HRI 串口记录；请手动选择一个。", "Windows returned duplicate HRI port records. Select one manually.") \
    X(cfg_saved_port_not_hri, "已保存的串口当前没有识别为 HRI。", "The saved port is not currently identified as HRI.") \
    X(cfg_cat_selection_invalid, "CAT 串口选择无效或与 HRI 串口冲突。", "The CAT port selection is invalid or conflicts with the HRI port.") \
    X(cfg_cat_port_missing_fmt, "选择的 CAT 串口 %s 当前没有枚举到。", "The selected CAT port %s is not currently present.") \
    X(cfg_duplicate_cat, "系统返回重复的 CAT 串口记录；请刷新设备列表后手动选择。", "Windows returned duplicate CAT port records. Refresh the device list and select the CAT port manually.") \
    X(cfg_cat_unclassified, "当前目录中未识别该端口的 CAT 身份；保留用户明确选择的 COM 口。", "The current device list cannot identify this port as CAT; keeping the explicitly selected COM port.") \
    X(cfg_multiple_cat, "发现多个同级 CAT 串口候选；为避免选错，请手动选择。", "Multiple CAT ports have the same match rank. Select one manually to avoid choosing the wrong port.") \
    X(cfg_no_cat_auto, "未找到可自动选择的 CAT 串口；可手动选择当前枚举的非 HRI 端口。", "No CAT port could be selected automatically. Choose a listed non-HRI port manually.") \
    X(cfg_saved_audio_missing, "已保存的音频 endpoint 当前没有枚举到；配置已保留。", "The saved audio endpoint is not currently present; its setting was kept.") \
    X(cfg_duplicate_audio, "系统返回重复的音频端点记录；请刷新设备列表或手动选择。", "Windows returned duplicate audio endpoint records. Refresh the device list or select an endpoint manually.") \
    X(cfg_audio_endpoint_reused, "沿用当前枚举到的稳定音频 endpoint ID。", "Keeping the stable audio endpoint ID found in the current device list.") \
    X(cfg_audio_start_match, "与启动配置相同的 USB Audio 自动选择结果。", "This USB audio selection matches the startup configuration.") \
    X(cfg_multiple_usb_audio, "发现多个 USB Audio 候选；请手动选择。", "Multiple USB audio devices were found. Select one manually.") \
    X(cfg_no_usb_audio, "当前没有 USB Audio 自动候选；请手动选择已枚举的端点。", "No USB audio device can be selected automatically. Choose a listed endpoint manually.") \
    X(cfg_choose_hri_first, "请先选择 HRI 串口，再使用 USB Audio 自动选择。", "Select the HRI port before using automatic USB audio selection.") \
    X(cfg_other_direction_multiple, "另一方向有多个 USB Audio 候选；请手动选择输入和输出设备。", "Multiple USB audio candidates were found for the other direction. Select input and output devices manually.") \
    X(cfg_manual_audio_pair_mismatch, "手动端点与唯一 USB Audio 配对不一致；请手动选择两个端点或恢复 Auto。", "The manual endpoint does not match the unique USB audio pair. Select both endpoints manually or restore Auto.") \
    X(cfg_other_direction_empty, "另一方向没有 USB Audio 自动候选；请手动选择输入和输出设备。", "No USB audio candidate is available for the other direction. Select input and output devices manually.") \
    X(cfg_audio_pair_unresolved, "当前设备组合不能自动选择；请手动选择输入和输出设备。", "This device combination cannot be selected automatically. Choose input and output devices manually.") \
    X(cfg_waveout_independent, "WaveOut 可独立选择；已按唯一 USB Audio 候选或唯一可用输出解析。", "WaveOut can be selected independently; using the only USB audio candidate or only available output.") \
    X(cfg_waveout_not_matched, "WaveOut 自动解析结果未在当前设备目录中唯一匹配；请手动选择。", "The automatic WaveOut selection has no unique match in the current device list. Select it manually.") \
    X(cfg_waveout_auto_none, "WaveOut 自动选择没有唯一结果；请手动选择。", "Automatic WaveOut selection did not find one unique result. Select it manually.") \
    X(cfg_active_serial, "连接状态报告当前实际使用的串口。", "Connection status reports this as the active serial port.") \
    X(cfg_active_serial_unmatched, "连接状态仍报告此串口，但最新设备目录没有唯一匹配项。", "Connection status still reports this port, but the latest device list has no unique match.") \
    X(cfg_active_audio, "引擎状态报告当前实际使用的音频 endpoint。", "Engine status reports this as the active audio endpoint.") \
    X(cfg_active_audio_unmatched, "引擎仍报告此 endpoint，但最新设备目录没有唯一匹配项。", "The engine still reports this endpoint, but the latest device list has no unique match.") \
    X(cfg_winmm_endpoint_missing, "本机 WinMM 未返回所选 WaveIn/WaveOut 的 endpoint ID；请检查 Windows 音频端点后重试。", "WinMM did not return an endpoint ID for the selected WaveIn/WaveOut device. Check the Windows audio endpoints and retry.") \
    X(cfg_audio_no_usable_output, "没有可用的 48 kHz 单声道 WaveOut 端点；来话仍会显示，请手动选择输出设备后重试。", "No usable 48 kHz mono WaveOut endpoint is available. Calls remain visible; select an output device and retry.") \
    X(cfg_audio_multiple_outputs, "发现多个可用的 WaveOut 端点；来话仍会显示，请手动选择输出设备。", "Multiple usable WaveOut endpoints were found. Calls remain visible; select an output device.") \
    X(cfg_audio_saved_output_missing, "已选择的 WaveOut endpoint 当前没有唯一枚举到；来话仍会显示，请刷新设备或手动选择。", "The selected WaveOut endpoint is not uniquely enumerated. Calls remain visible; refresh devices or select an output manually.") \
    X(cfg_audio_no_usable_input, "没有可用的 48 kHz WaveIn 端点；请检查电台 USB 音频连接后重试。", "No usable 48 kHz WaveIn endpoint is available. Check the radio's USB audio connection and retry.") \
    X(cfg_audio_input_not_unique, "WaveIn endpoint 无法按 USB Audio 关键词唯一确定；请在设置中选择稳定 endpoint ID。", "A unique WaveIn endpoint could not be identified by the USB Audio name. Select a stable endpoint ID in settings.") \
    X(cfg_audio_output_not_unique, "WaveOut endpoint 无法按 USB Audio 关键词唯一确定；请在设置中选择稳定 endpoint ID。", "A unique WaveOut endpoint could not be identified by the USB Audio name. Select a stable endpoint ID in settings.") \
    X(cfg_audio_saved_input_missing, "连接配置指定的 WaveIn endpoint 当前未唯一枚举到；请检查设备后重试。", "The WaveIn endpoint in the connection settings is not uniquely enumerated. Check the device and retry.") \
    X(cfg_audio_connection_saved_output_missing, "连接配置指定的 WaveOut endpoint 当前未唯一枚举到；请检查设备后重试。", "The WaveOut endpoint in the connection settings is not uniquely enumerated. Check the device and retry.")

// Native window/CLI startup errors are shown before the config language can load.
#define WIREX_GUI_STRINGS_STARTUP(X) \
    X(cli_parse_failed, "无法解析命令行。", "Could not parse the command line.") \
    X(cli_lang_arg, "--lang 需要 zh-CN 或 en-US。", "--lang requires zh-CN or en-US.") \
    X(cli_screenshot_modal_value, "--screenshot-modal 只支持 remove-static。", "--screenshot-modal only supports remove-static.") \
    X(cli_config_path, "--config 需要 config.json 路径。", "--config requires a config.json path.") \
    X(cli_config_path_invalid, "config.json 路径无效。", "The config.json path is invalid.") \
    X(cli_screenshot_path, "--screenshot 需要 PNG 路径。", "--screenshot requires a PNG path.") \
    X(cli_screenshot_path_invalid, "截图路径无效。", "The screenshot path is invalid.") \
    X(cli_unknown_arg_fmt, "未知参数：%s", "Unknown argument: %s") \
    X(cli_usage, "用法：WirexBridge.exe [--fake [--fake-services]] [--config <json>] [--screenshot <png>] [--lang zh-CN|en-US] [--screenshot-modal remove-static] [--screenshot-relay-demo] [--screenshot-channel-states] [--screenshot-bm-cooldown] [--screenshot-update-available] [--check-config]", "Usage: WirexBridge.exe [--fake [--fake-services]] [--config <json>] [--screenshot <png>] [--lang zh-CN|en-US] [--screenshot-modal remove-static] [--screenshot-relay-demo] [--screenshot-channel-states] [--screenshot-bm-cooldown] [--screenshot-update-available] [--check-config]") \
    X(cli_fake_services_requires_fake, "--fake-services 只能与 --fake 一起使用。", "--fake-services can only be used with --fake.") \
    X(cli_screenshot_modal_requires_fake, "--screenshot-modal 只能与 --fake 和 --screenshot 一起使用。", "--screenshot-modal requires both --fake and --screenshot.") \
    X(cli_screenshot_channels_requires_fake, "--screenshot-channel-states / --screenshot-bm-cooldown 只能与 --fake 和 --screenshot 一起使用。", "--screenshot-channel-states and --screenshot-bm-cooldown require both --fake and --screenshot.") \
    X(cli_screenshot_relay_requires_fake, "--screenshot-relay-demo 只能与 --fake 和 --screenshot 一起使用。", "--screenshot-relay-demo requires both --fake and --screenshot.") \
    X(cli_screenshot_update_requires_fake, "--screenshot-update-available 只能与 --fake 和 --screenshot 一起使用。", "--screenshot-update-available requires both --fake and --screenshot.") \
    X(err_register_class, "RegisterClassExW 失败。", "RegisterClassExW failed.") \
    X(err_create_window, "CreateWindowExW 失败。", "CreateWindowExW failed.") \
    X(err_create_d3d_device, "无法创建 Direct3D 11 设备。", "Could not create the Direct3D 11 device.") \
    X(err_imgui_backend, "Dear ImGui backend 初始化失败。", "Could not initialize the Dear ImGui backend.") \
    X(err_create_event, "CreateEventW 失败。", "CreateEventW failed.") \
    X(err_resize_swap_chain, "调整交换链大小失败。", "Could not resize the swap chain.") \
    X(err_screenshot_fmt, "截图失败：%s", "Screenshot failed: %s") \
    X(err_d3d_device_lost, "Direct3D 设备已丢失。", "The Direct3D device was lost.") \
    X(err_unhandled_exception_fmt, "未处理的异常：%s", "Unhandled exception: %s") \
    X(err_unhandled_exception, "未处理的异常。", "An unhandled exception occurred.") \
    X(err_create_bridge_engine_fmt, "无法创建桥接引擎：%s", "Could not create the bridge engine: %s")
// clang-format on

enum class Str : std::uint16_t {
#define WIREX_GUI_STR_ENUM(key, zh, en) key,
    WIREX_GUI_STRINGS(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_R131(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_HRI_POWER(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_R133(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_QUICK_CALL_DEFERRAL(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_RADIO_BM_DECOUPLING(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_R135(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_R136(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_R136_CALLER_REGION(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_R136_TITLE_LINKS(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_VIEW_MODEL(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_CONFIG_BRIDGE(WIREX_GUI_STR_ENUM)
    WIREX_GUI_STRINGS_STARTUP(WIREX_GUI_STR_ENUM)
#undef WIREX_GUI_STR_ENUM
        count_
};

enum class Language : std::uint8_t { zh_cn, en_us };

inline constexpr bool kHonorConfigLanguage = true;

namespace detail {
struct StrEntry {
    const char* zh;
    const char* en;
};
inline constexpr StrEntry kStrings[] = {
#define WIREX_GUI_STR_ROW(key, zh, en) {zh, en},
    WIREX_GUI_STRINGS(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_R131(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_HRI_POWER(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_R133(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_QUICK_CALL_DEFERRAL(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_RADIO_BM_DECOUPLING(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_R135(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_R136(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_R136_CALLER_REGION(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_R136_TITLE_LINKS(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_VIEW_MODEL(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_CONFIG_BRIDGE(WIREX_GUI_STR_ROW)
    WIREX_GUI_STRINGS_STARTUP(WIREX_GUI_STR_ROW)
#undef WIREX_GUI_STR_ROW
};
static_assert(sizeof(kStrings) / sizeof(kStrings[0]) == static_cast<std::size_t>(Str::count_));

inline std::atomic<Language> g_language{Language::zh_cn};
} // namespace detail

inline void set_language(Language language) noexcept { detail::g_language.store(language, std::memory_order_relaxed); }
[[nodiscard]] inline Language language() noexcept { return detail::g_language.load(std::memory_order_relaxed); }

// config 中的 ui.language；未知值回落到 zh-CN。
[[nodiscard]] inline Language parse_language(std::string_view tag) noexcept {
    return tag == "en-US" ? Language::en_us : Language::zh_cn;
}

[[nodiscard]] inline const char* tr(Str key) noexcept {
    const auto& row = detail::kStrings[static_cast<std::size_t>(key)];
    return language() == Language::en_us ? row.en : row.zh;
}

} // namespace wirex::gui
