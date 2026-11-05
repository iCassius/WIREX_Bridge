#pragma once

// GUI 文案表：键 → zh-CN 源文案 / en-US 译文。
// en-US 优先复用 ui/windows/UiLocalization.psm1 词典中的译文；词典里没有的条目在行尾标注 "new"。
// 运行时支持中英文切换；用户选择保存在 config 的 ui.language。
// 含 printf 占位符的条目两列占位符顺序与类型必须一致。

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace wirex::gui {

// clang-format off
#define WIREX_GUI_STRINGS(X) \
    X(app_title,            "WIREX BRIDGE  ·  FTX-1",              "WIREX BRIDGE  ·  FTX-1") \
    X(window_title,         "WIREX Bridge · FTX-1",                "WIREX Bridge · FTX-1") \
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
    X(filtered_group_fmt,   "BM 有流量未收听：TG %u TS%d（来自 %u）· %u 秒前", \
                            "Unheard BM traffic: TG %u TS%d (from %u) · %us ago") /* new */ \
    X(filtered_private_fmt, "BM 有流量未收听：单呼 TS%d（来自 %u）· %u 秒前", \
                            "Unheard BM traffic: private TS%d (from %u) · %us ago") /* new */ \
    X(filtered_join,        "加入收听",                            "Listen")                        /* new */ \
    X(tip_filtered_join,    "把该 TG/时隙加入频道列表并开始收听。", \
                            "Add this TG/slot to the channel list and start listening.") /* new */ \
    X(tip_filtered_private_join, "把该私呼对端加入私呼频道并开始收听。", \
                            "Add this private-call peer as a private channel and start listening.") /* new */
// clang-format on

enum class Str : std::uint16_t {
#define WIREX_GUI_STR_ENUM(key, zh, en) key,
    WIREX_GUI_STRINGS(WIREX_GUI_STR_ENUM)
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
#undef WIREX_GUI_STR_ROW
};
static_assert(sizeof(kStrings) / sizeof(kStrings[0]) == static_cast<std::size_t>(Str::count_));

inline Language g_language = Language::zh_cn;
} // namespace detail

inline void set_language(Language language) noexcept { detail::g_language = language; }
[[nodiscard]] inline Language language() noexcept { return detail::g_language; }

// config 中的 ui.language；未知值回落到 zh-CN。
[[nodiscard]] inline Language parse_language(std::string_view tag) noexcept {
    return tag == "en-US" ? Language::en_us : Language::zh_cn;
}

[[nodiscard]] inline const char* tr(Str key) noexcept {
    const auto& row = detail::kStrings[static_cast<std::size_t>(key)];
    return detail::g_language == Language::en_us ? row.en : row.zh;
}

} // namespace wirex::gui
