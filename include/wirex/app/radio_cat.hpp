#pragma once

// FTX-1 CAT-1 客户端（R128 原生重构，对应 ui/windows/RadioCat.psm1 + RadioCatUi.ps1 的门控部分）。
// - CatClient 为同步实现：每次操作打开短会话串口，逐条发送 `XX...;` 并读回，不自动重试，结束即关闭。
// - 解析、帧构造、核心门控均为纯函数，便于表驱动测试。
// - CatWorker 自带线程与任务队列，供 UI 投递；断开时撤销写授权、保留最后一次观测值（R119/R123 语义）。

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>

namespace wirex::app {

// ---------- 协议常量 ----------

inline constexpr std::size_t cat_max_frame_length = 64U;
inline constexpr std::uint32_t cat_min_frequency_hz = 30000U;
inline constexpr std::uint32_t cat_max_frequency_hz = 470000000U;
inline constexpr int cat_app_min_power_watts = 5;
inline constexpr int cat_app_max_power_watts = 50;
inline constexpr std::string_view cat_expected_radio_id = "0840";
inline constexpr std::string_view cat_source_serial = "FTX-1 CAT-1";
inline constexpr std::chrono::milliseconds cat_default_timeout{2500};
inline constexpr std::chrono::milliseconds cat_min_timeout{100};
inline constexpr std::chrono::milliseconds cat_max_timeout{3000};
/// 功率门控：核心空闲状态必须在此时间窗内被确认（PS: Test-UiRadioCatRunIdle -RequireFreshStatus）。
inline constexpr std::chrono::milliseconds cat_idle_status_max_age{3000};
/// 写授权：最近一次确认的 query 必须在此时间窗内完成（PS: Test-UiRadioCatFreshQueryAuthorization）。
inline constexpr std::chrono::milliseconds cat_write_permit_max_age{3000};

enum class CatCommand : std::uint8_t { id, ai, tx, fa, fb, md, pc };
enum class CatSide : std::uint8_t { main, sub };
enum class CatPowerPath : std::uint8_t { field_head, spa1 };

/// FTX-1 CAT 手册 2512-D 的 MD 代码；G 为保留值，不在表中。
enum class CatMode : std::uint8_t {
    unused, lsb, usb, cw_u, fm, am, rtty_l, cw_l, data_l, rtty_u,
    data_fm, fm_n, data_u, am_n, psk, data_fm_n, c4fm_dn, c4fm_vw,
};

enum class CatStopBits : std::uint8_t { one, two };

enum class CatError : std::uint8_t {
    none,
    // 帧/协议
    invalid_frame,
    radio_rejected_command,
    unexpected_response,
    frequency_out_of_range,
    unknown_mode_code,
    power_out_of_range,
    side_mismatch,
    // 操作语义
    identity_mismatch,
    busy,
    hri_port_conflict,
    invalid_request,
    power_mode_not_supported,
    readback_mismatch,
    // 门控（原 PS 在 UI 层抛出；原生版本以错误码返回，均在打开串口/写入前生效）
    gate_transmitting,       // 发射中（引擎上行或电台 TX 非 0）；发射结束后可重试
    gate_hri_downlink,       // HRI 下行播放中改频率/模式；来话结束后可重试
    write_not_authorized,
    // 传输
    timeout,
    cancelled,
    port_busy_or_denied,
    serial_io_error,
    serial_close_failed,
};

enum class CatResultStatus : std::uint8_t { confirmed, busy, identity_mismatch, rejected, mismatch, unknown };
enum class CatCleanup : std::uint8_t { not_opened, closed, close_failed };
enum class CatOperation : std::uint8_t { query, set_power, set_mode, set_frequency };

[[nodiscard]] std::string_view to_string(CatMode mode) noexcept;
[[nodiscard]] std::string_view to_string(CatError error) noexcept;
[[nodiscard]] std::string_view to_string(CatResultStatus status) noexcept;
[[nodiscard]] std::optional<CatMode> cat_mode_from_code(char code) noexcept;
[[nodiscard]] std::optional<CatMode> cat_mode_from_name(std::string_view name) noexcept;  // 大小写不敏感
[[nodiscard]] char cat_mode_code(CatMode mode) noexcept;
[[nodiscard]] bool cat_is_voice_mode(CatMode mode) noexcept;  // FM / FM-N / C4FM-DN / C4FM-VW
[[nodiscard]] int cat_power_path_max_watts(CatPowerPath path) noexcept;  // 应用上限：FieldHead 10，SPA-1 50
/// PS 状态映射（Invoke-Ftx1CatOperation catch 分支）。
[[nodiscard]] CatResultStatus cat_status_for_error(CatError error) noexcept;

// ---------- 帧构造（纯函数） ----------

[[nodiscard]] std::string_view cat_read_command(CatCommand command) noexcept;  // "ID;" ... ；MD 用下面的函数
[[nodiscard]] std::string_view cat_mode_read_command(CatSide side) noexcept;   // "MD0;" / "MD1;"
/// FA 九位定长；越界返回 nullopt（不钳位）。
[[nodiscard]] std::optional<std::string> cat_frequency_command(std::uint32_t frequency_hz);
/// 仅允许语音模式（FM/FM-N/C4FM-DN/C4FM-VW）。
[[nodiscard]] std::optional<std::string> cat_mode_command(CatSide side, CatMode mode);
/// 5..路径上限；越界返回 nullopt（不钳位）。
[[nodiscard]] std::optional<std::string> cat_power_command(CatPowerPath path, int watts);

// ---------- 应答解析（纯函数） ----------

struct CatModeReading {
    CatSide side{CatSide::main};
    CatMode mode{CatMode::unused};
    friend bool operator==(const CatModeReading& a, const CatModeReading& b) noexcept
    {
        return a.side == b.side && a.mode == b.mode;
    }
};

struct CatPowerReading {
    CatPowerPath path{CatPowerPath::spa1};
    int watts{};
    friend bool operator==(const CatPowerReading& a, const CatPowerReading& b) noexcept
    {
        return a.path == b.path && a.watts == b.watts;
    }
};

enum class CatFrameStatus : std::uint8_t { ok, radio_error, protocol_error };

struct CatFrame {
    CatFrameStatus status{CatFrameStatus::protocol_error};
    CatError error{CatError::invalid_frame};
    std::string radio_id{};          // ID
    bool auto_information{};         // AI
    int tx_state{};                  // TX：0 接收，1/2 发射
    std::uint32_t frequency_hz{};    // FA / FB
    CatModeReading mode{};           // MD
    CatPowerReading power{};         // PC（解析范围 FieldHead 5..10，SPA-1 5..100）
};

/// 对应 ConvertFrom-Ftx1CatFrame：严格匹配 expected 命令的完整帧（含末尾 ';'）。
[[nodiscard]] CatFrame cat_parse_frame(std::string_view frame, CatCommand expected);
/// 通用帧语法 ^[A-Z]{2}[\x20-\x7E]*;$；成功时输出两字母命令。
[[nodiscard]] bool cat_frame_command(std::string_view frame, std::string_view& command) noexcept;

/// 字节流组帧：只接受可打印 ASCII，遇 ';' 结束，超过 64 字节视为无效。
class CatFrameAssembler final {
public:
    enum class Step : std::uint8_t { need_more, complete, invalid };
    [[nodiscard]] Step push(char byte, std::string& complete_frame);
    void reset() noexcept { buffer_.clear(); }

private:
    std::string buffer_{};
};

/// 归一化端口名：去空白、转大写、去 `\\.\` 前缀、COM0011→COM11。
[[nodiscard]] std::wstring cat_normalize_port_name(std::wstring_view port);
/// 仅接受 COM1..COM999（归一化之后）。
[[nodiscard]] bool cat_is_valid_port_name(std::wstring_view normalized_port) noexcept;

// ---------- 核心门控（纯函数） ----------

/// 门控输入由调用方从引擎 Snapshot 填写（R131 重设计）。
/// 引擎常驻、从不停止，因此不再以“核心已停止/空闲”为条件；只保留真正有安全意义的约束：
/// - 电台/引擎正在发射（手咪 PTT 上行、FM 中继上行）时禁止任何设置；
/// - HRI 已连接且正在向电台下行播放（media_owner 为 rx_*）时禁止改频率/模式，避免打断正在发出的 RF。
/// BM 断开、引擎空闲、HRI 已连接但空闲、仅 BM 本机播放等情况一律允许。
/// 电台自身的 `TX;` 状态由 CatClient 在会话内另行检查（非 0 → CatError::busy）。
struct CatCoreState {
    /// 引擎 tx_active、relay_fm_active 或 media_owner 为 tx_active/tx_draining。
    bool transmitting{};
    /// HRI 已就绪且 media_owner 为 rx_active/rx_draining/rx_stopping（来话正经电台发出）。
    bool hri_downlink_active{};
};

enum class CatGateDecision : std::uint8_t { allowed, transmitting, hri_downlink_active };

/// 设置 MAIN 频率或模式：发射中或 HRI 下行播放中禁止。
[[nodiscard]] CatGateDecision cat_gate_mode_or_frequency(const CatCoreState& core) noexcept;
/// 设置功率：只在发射中禁止。now 参数保留以兼容调用方（不再使用空闲时间戳）。
[[nodiscard]] CatGateDecision cat_gate_power(const CatCoreState& core,
                                             std::chrono::steady_clock::time_point now) noexcept;
[[nodiscard]] CatGateDecision cat_gate_for(CatOperation operation, const CatCoreState& core,
                                           std::chrono::steady_clock::time_point now) noexcept;
/// 每次门控判定（操作开始前、写帧前各一次）都会重新调用以取得最新核心状态。
using CatCoreStateProvider = std::function<CatCoreState()>;

// ---------- 观测值 / 结果 ----------

template <class T>
struct CatObservation {
    T value{};
    std::chrono::system_clock::time_point updated_at{};
    std::string source{};
};

struct CatObserved {
    std::optional<CatObservation<std::string>> radio_id{};
    std::optional<CatObservation<bool>> auto_information{};
    std::optional<CatObservation<int>> tx_state{};
    std::optional<CatObservation<std::uint32_t>> main_frequency_hz{};
    std::optional<CatObservation<std::uint32_t>> sub_frequency_hz{};
    std::optional<CatObservation<CatModeReading>> main_mode{};
    std::optional<CatObservation<CatModeReading>> sub_mode{};
    std::optional<CatObservation<CatPowerReading>> power{};
};

/// 对应 Merge-UiRadioCatObserved：只用 fresh 中有值的字段覆盖 existing。
void cat_merge_observed(CatObserved& existing, const CatObserved& fresh);

struct CatCapabilities {
    bool query_available{};
    bool set_frequency_available{};
    bool set_mode_available{};
    bool set_power_available{};
    bool power_readable{};
    std::optional<CatPowerPath> power_path{};
    std::optional<int> power_maximum_watts{};
};

struct CatResult {
    CatOperation operation{CatOperation::query};
    CatResultStatus status{CatResultStatus::unknown};
    CatError error{CatError::none};
    std::string error_message{};
    std::string source{};           // 仅在有观测且已确认时填写
    std::wstring port_name{};
    std::chrono::system_clock::time_point started_at{};
    std::optional<std::chrono::system_clock::time_point> updated_at{};
    CatCleanup cleanup{CatCleanup::not_opened};
    CatObserved observed{};
    CatCapabilities capabilities{};
    // prior：写操作读到的旧值（未写入时也会填写）
    std::optional<CatModeReading> prior_mode{};
    std::optional<std::uint32_t> prior_frequency_hz{};
    std::optional<CatPowerReading> prior_power{};
};

// ---------- 传输 ----------

struct CatConnection {
    std::wstring port_name{};             // CAT-1，例如 L"COM11"
    std::wstring hri_port_name{};         // 当前 HRI 端口；相同则拒绝打开
    std::uint32_t baud_rate{38400U};      // 4800/9600/19200/38400/115200
    CatStopBits stop_bits{CatStopBits::two};  // 8N2
    std::chrono::milliseconds timeout{cat_default_timeout};  // 整个会话的期限，100..3000 ms
};

[[nodiscard]] bool cat_is_supported_baud_rate(std::uint32_t baud_rate) noexcept;
/// "COM11|38400|Two" 形式；用于写授权与观测值归属。
[[nodiscard]] std::wstring cat_connection_key(const CatConnection& connection);

enum class CatIo : std::uint8_t { ok, timeout, cancelled, io_error, invalid_data, denied };

class CatTransport {
public:
    virtual ~CatTransport() = default;
    virtual CatIo open() = 0;
    virtual CatIo clear_input() = 0;
    virtual CatIo write_frame(std::string_view frame, std::chrono::milliseconds timeout) = 0;
    /// 读取一个完整帧（含 ';'）；期限内无完整帧返回 timeout。
    virtual CatIo read_frame(std::string& frame, std::chrono::milliseconds timeout,
                             const std::atomic<bool>* cancel) = 0;
    virtual CatIo close() = 0;
    [[nodiscard]] virtual std::string source_label() const = 0;
};

using CatTransportFactory = std::function<std::unique_ptr<CatTransport>(const CatConnection&)>;

/// Win32 串口：CreateFileW + SetCommState(8 数据位、无校验、指定停止位、关闭 DTR/RTS 与流控) + SetCommTimeouts。
[[nodiscard]] std::unique_ptr<CatTransport> make_win32_cat_transport(const CatConnection& connection);

/// 诊断：逐帧回调（tx=true 为发送帧，false 为收到的完整帧）。CAT 帧不含凭据，可原文记录。
/// 回调在 CAT worker 线程上同步调用，必须快速且不抛异常（抛出的异常被吞掉）。
using CatFrameTrace = std::function<void(bool tx, std::string_view frame, std::string_view port)>;
/// 包装任意传输工厂：每次 write_frame 记录发送帧；read_frame 成功时记录收到的帧；读写失败记录 IO 结果。
[[nodiscard]] CatTransportFactory make_traced_cat_transport_factory(CatTransportFactory inner, CatFrameTrace trace);

// ---------- R130：FM 中继静噪快速采样（只读） ----------

/// `SM0nnn;` → 0..255；其它（含 `?;`）返回 nullopt。
[[nodiscard]] std::optional<unsigned> cat_parse_s_meter(std::string_view frame) noexcept;

struct CatSquelchSample {
    CatError error{CatError::none};       // none：RI0 应答已取得且通过 radio_info::parse
    std::string error_message{};
    std::string ri_frame{};               // 原始 `RI........;`（error==none 时有效）
    std::optional<unsigned> s_meter{};    // SM0 值；不应答 / `?;` / 超时时为空，不影响 RI 结果
    CatCleanup cleanup{CatCleanup::not_opened};
};

// ---------- 同步客户端 ----------

class CatClient final {
public:
    CatClient();  // 默认使用 Win32 串口
    explicit CatClient(CatTransportFactory factory);

    /// 只读：ID→AI→TX→FA→FB→MD0→MD1→PC。ID 必须为 0840。
    [[nodiscard]] CatResult query_all(const CatConnection& connection,
                                      const std::atomic<bool>* cancel = nullptr) const;
    /// MAIN FA 频率。要求核心已停止、ID0840、TX0，写前再读一次 TX，写后 FA 读回核对。
    [[nodiscard]] CatResult set_main_frequency(const CatConnection& connection, std::uint32_t frequency_hz,
                                               const CatCoreStateProvider& core,
                                               const std::atomic<bool>* cancel = nullptr) const;
    /// MAIN/SUB 模式（仅语音模式）。门控同频率。
    [[nodiscard]] CatResult set_mode(const CatConnection& connection, CatSide side, CatMode mode,
                                     const CatCoreStateProvider& core,
                                     const std::atomic<bool>* cancel = nullptr) const;
    /// 功率设置值（非实测输出）。要求核心空闲、MAIN 为语音模式、目标在当前路径范围内。
    /// force_write 用于 HRI 显示回显，强制写 PC2，即使当前读数已经相同。
    [[nodiscard]] CatResult set_power(const CatConnection& connection, int watts,
                                      const CatCoreStateProvider& core,
                                      const std::atomic<bool>* cancel = nullptr,
                                      bool force_write = false) const;
    /// R130 只读静噪采样：短会话只发 `RI0;` 与 `SM0;`（不发 ID/AI，身份由 1 s 周期 query 保证）。
    /// SM0 失败不影响 RI 结果。不改动任何写授权或观测值。
    [[nodiscard]] CatSquelchSample query_squelch(const CatConnection& connection,
                                                 const std::atomic<bool>* cancel = nullptr) const;

private:
    struct Request;
    [[nodiscard]] CatResult run(const Request& request) const;
    CatTransportFactory factory_;
};

// ---------- 后台 worker ----------

struct CatJob {
    CatOperation operation{CatOperation::query};
    CatConnection connection{};
    CatSide side{CatSide::main};
    CatMode mode{CatMode::fm};
    std::uint32_t frequency_hz{};
    int power_watts{};
    bool force_power_write{};
};

struct CatWorkerSnapshot {
    std::uint64_t generation{};               // 每次 disconnect +1
    std::wstring observed_connection_key{};   // 观测值所属连接
    CatObserved observed{};                   // 断开后仍保留
    std::optional<CatCapabilities> capabilities{};  // 最近一次确认结果的能力；断开或失败时清空
    bool write_authorized{};
    std::optional<std::chrono::steady_clock::time_point> write_permit_at{};
    std::optional<CatResult> last_result{};
    bool busy{};
};

/// 写授权（纯函数，对应 Test-UiRadioCatFreshQueryAuthorization）：确认的 query、端口已关闭、ID0840、TX0、
/// 同一连接、同一代、且在 3 s 内完成。
[[nodiscard]] bool cat_query_grants_write_permit(const CatResult& query_result) noexcept;
[[nodiscard]] bool cat_write_permit_fresh(std::chrono::steady_clock::time_point permit_at,
                                          std::chrono::steady_clock::time_point now) noexcept;

class CatWorker final {
public:
    using Callback = std::function<void(const CatResult&)>;

    CatWorker(CatClient client, CatCoreStateProvider core_state);
    ~CatWorker();  // 取消当前操作、丢弃队列并等待线程结束
    CatWorker(const CatWorker&) = delete;
    CatWorker& operator=(const CatWorker&) = delete;

    /// 投递任务；结果经 future 返回，callback（可空）在 worker 线程上调用，必须非阻塞。
    /// 写任务：若写授权不新鲜，会先自动执行一次 query（冻结目标后读取，PS 的 queued-action 流程），
    /// 通过后才写入；否则返回 rejected/write_not_authorized。
    std::future<CatResult> submit(CatJob job, Callback callback = {});
    /// 取消当前操作（结果为 unknown/cancelled，不会在取消后发送写帧）。
    void cancel_current() noexcept;
    /// 断开：代号 +1，取消当前操作与队列，撤销写授权，保留观测值。
    void disconnect();
    [[nodiscard]] CatWorkerSnapshot snapshot() const;

private:
    struct Pending {
        CatJob job;
        Callback callback;
        std::promise<CatResult> promise;
        std::uint64_t generation{};
    };

    void loop();
    [[nodiscard]] CatResult execute(const CatJob& job, std::uint64_t generation);
    void absorb(const CatResult& result, const CatJob& job, std::uint64_t generation);
    [[nodiscard]] static CatResult cancelled_result(const CatJob& job);

    CatClient client_;
    CatCoreStateProvider core_state_;
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Pending> queue_;
    std::atomic<bool> cancel_{false};
    bool stopping_{false};
    CatWorkerSnapshot state_{};
    std::thread thread_;
};

} // namespace wirex::app
