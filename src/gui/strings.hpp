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
    X(core,                 "核心",                                "Core")                          /* new */ \
    X(language_english,     "English",                             "English") \
    X(language_chinese,     "中文",                                 "Chinese") \
    X(relay_unknown,        "中继未知",                            "Relay ?")                        /* new */ \
    X(relay_unavailable_reason,"中继控制尚未接入可验证的引擎命令；目前不能确认中继已启用或关闭。", \
                            "Relay control is not connected to a verifiable engine command; its enabled state is unknown.") /* new */ \
    X(manual_dmr_id,        "BM DMR ID（手动）",                    "BM DMR ID (manual)")             /* new */ \
    X(manual_dmr_id_hint,   "DMR ID 必须由用户手动填写；不会根据呼号自动补全。", \
                            "Enter the DMR ID manually; it is never inferred from the callsign.") /* new */ \
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
    X(tip_quick_call,       "向本机 Native 请求发送一次动态组 Quick Call；本机只报告发送结果，不回读 BM 当前动态组。", \
                            "Send one dynamic group Quick Call to local Native. The local result reports transmission only; it does not read back the current BM dynamic group.") \
    X(tip_quick_pending,    "一项激活请求正在等待本机结果；结果返回或等待超时后可再次操作。", \
                            "An activation request is waiting for a local result. Try again after a result or timeout.") \
    X(tip_static,           "TG %u TS%d；静态组已读取。",          "TG %u TS%d; static group read back.")   /* new */ \
    X(tip_dynamic_sent,     "TG %u TS%d；本机已发送上一条激活请求，BM 当前动态组状态未知。", \
                            "TG %u TS%d; the previous request was sent locally; BM dynamic group state is unknown.") /* new */ \
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
    X(cat_disconnected,     "CAT 未连接",                          "CAT not connected")             /* new */ \
    X(cat_connecting,       "CAT 正在连接或执行命令…",           "CAT connecting or handling a command…") \
    X(active_serials_fmt,   "实际串口：HRI %s · CAT %s",          "Active ports: HRI %s · CAT %s") \
    X(cat_observed,         "读取：%s · %.4f MHz · %u W",          "Read: %s · %.4f MHz · %u W")    /* new */ \
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
    X(port_missing_fmt,     "%s（当前未检测到）",                "%s (not detected)") \
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
    X(audio_devices_failed, "音频切换未确认，请检查设备后重试。", "Audio switch was not confirmed. Check devices and retry.") \
    X(audio_devices_next_connection,"下次连接时使用所选设备。",    "Selected devices will be used on the next connection.") \
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
    X(channel_idle,         "空闲",                                "Idle")                          /* new */ \
    X(last_call_fmt,        "上次 %s",                             "Last %s")                       /* new */ \
    X(auto_select,          "自动",                                "Auto")                          /* new */ \
    X(muted_badge,          "已屏蔽",                              "Muted")                         /* new */
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
