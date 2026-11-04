#pragma once

#include "wirex/bm_session.hpp"
#include "wirex/bm_udp.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>

namespace wirex::bm_connection {

enum class ResolveResult : std::uint8_t {
    pending,
    resolved,
    failed,
    cancelled,
};

class MasterResolver {
public:
    virtual ~MasterResolver() = default;
    [[nodiscard]] virtual ResolveResult start(std::string_view host, std::uint16_t port,
                                              bm::Endpoint& endpoint) noexcept = 0;
    [[nodiscard]] virtual ResolveResult poll(bm::Endpoint& endpoint) noexcept = 0;
    virtual void cancel() noexcept = 0;
    [[nodiscard]] virtual bool pending() const noexcept = 0;
};

[[nodiscard]] std::unique_ptr<MasterResolver> make_system_master_resolver();

enum class Error : std::uint8_t {
    none,
    password_required,
    master_resolution_failed,
    master_resolution_timeout,
    resolver_cancel_timeout,
    profile_invalid,
    transport_open_failed,
    media_cleanup_timeout,
    master_rejected,
    session_failed,
};

[[nodiscard]] const char* error_name(Error error) noexcept;

enum class RequestResult : std::uint8_t {
    accepted,
    idempotent,
    stale_revision,
    revision_conflict,
    transition_busy,
    password_required,
    master_resolution_failed,
    profile_invalid,
    transport_open_failed,
};

[[nodiscard]] const char* request_error_name(RequestResult result) noexcept;

struct Snapshot {
    bool requested_enabled{};
    std::uint64_t revision{};
    bool transport_open{};
    bool resolving{};
    bm::State bm_state{bm::State::stopped};
    Error error{Error::none};
};

// 在一个 HRI core 运行期间持有 BM 协议会话与 UDP transport。
// disable 请求先登记关闭意图；调用方完成有界 TX/RX/HRI 收尾后再调用
// begin_disable()，尽力发送待发 RPTCL，最后调用 finish_disable() 关闭 UDP。
class ConnectionControl final {
public:
    ConnectionControl(bm::Profile profile, std::string master_host, std::uint16_t master_port,
                      std::unique_ptr<MasterResolver> resolver = {});
    ConnectionControl(const ConnectionControl&) = delete;
    ConnectionControl& operator=(const ConnectionControl&) = delete;
    ~ConnectionControl();

    // 兼容原有组合启动顺序：先启动 Session，再打开 COM；HRI 串口预读成功后调用
    // open_initial_transport() 打开 UDP。
    [[nodiscard]] bool start_initial_session(const bm::Endpoint& endpoint,
                                             std::uint64_t now_ms) noexcept;
    [[nodiscard]] bool open_initial_transport() noexcept;
    void abort_initial_startup(std::uint64_t now_ms) noexcept;

    // revision 是本次请求的新版本；初始 snapshot revision=0 时第一次请求传 1。
    [[nodiscard]] RequestResult set_enabled(bool enabled, std::uint64_t revision,
                                            std::uint64_t now_ms) noexcept;
    [[nodiscard]] RequestResult configure(bm::Profile profile, std::string master_host,
                                          std::uint16_t master_port) noexcept;
    void tick(std::uint64_t now_ms) noexcept;
    [[nodiscard]] bool disable_pending() const noexcept { return disable_pending_; }
    [[nodiscard]] bool disable_cleanup_pending() const noexcept
    {
        return disable_pending_ || stop_queued_ || resolver_cleanup_pending_;
    }
    [[nodiscard]] bool begin_disable(std::uint64_t now_ms) noexcept;
    void finish_disable() noexcept;
    void note_media_cleanup_timeout() noexcept { error_ = Error::media_cleanup_timeout; }
    void cancel_pending_resolution(std::uint64_t now_ms) noexcept;

    [[nodiscard]] Snapshot snapshot() const noexcept;
    [[nodiscard]] bm::Session& session() noexcept { return session_; }
    [[nodiscard]] const bm::Session& session() const noexcept { return session_; }
    [[nodiscard]] bm::UdpTransport& transport() noexcept { return transport_; }
    [[nodiscard]] const bm::UdpTransport& transport() const noexcept { return transport_; }
    [[nodiscard]] const bm::Endpoint& endpoint() const noexcept { return initial_endpoint_; }

private:
    [[nodiscard]] RequestResult start_resolved_session(const bm::Endpoint& endpoint,
                                                       std::uint64_t now_ms) noexcept;
    void poll_resolver(std::uint64_t now_ms) noexcept;

    bm::Profile profile_{};
    std::string master_host_{};
    std::uint16_t master_port_{};
    bm::Endpoint initial_endpoint_{};
    std::unique_ptr<MasterResolver> resolver_{};
    bm::Session session_{};
    bm::UdpTransport transport_{};
    bool requested_enabled_{};
    std::uint64_t revision_{};
    bool resolving_{};
    std::uint64_t resolving_revision_{};
    std::uint64_t resolve_deadline_ms_{};
    bool resolver_cleanup_pending_{};
    std::uint64_t resolver_cancel_deadline_ms_{};
    bool disable_pending_{};
    bool stop_queued_{};
    Error error_{Error::none};
    bool last_request_valid_{};
    bool last_request_enabled_{};
    RequestResult last_request_result_{RequestResult::transition_busy};
};

} // namespace wirex::bm_connection
