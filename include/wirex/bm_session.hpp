#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <vector>

namespace wirex::bm {

inline constexpr std::size_t dmrd_datagram_size = 55U;
inline constexpr std::uint32_t max_gateway_id = 0xffffffffU;
inline constexpr std::size_t max_queued_datagrams = 128U;

struct Endpoint {
    // IPv4 地址按网络字节顺序保存，之后是 UDP 端口。
    std::array<std::uint8_t, 4> address{};
    std::uint16_t port{};

    [[nodiscard]] bool operator==(const Endpoint& other) const noexcept;
    [[nodiscard]] bool operator!=(const Endpoint& other) const noexcept;
};

struct Profile {
    std::uint32_t gateway_id{};
    std::string password;
    std::string callsign;
    std::uint32_t rx_frequency{};
    std::uint32_t tx_frequency{};
    std::uint8_t power{};
    std::uint8_t color_code{};
    std::string latitude;
    std::string longitude;
    std::uint16_t height{};
    std::string location;
    std::string description;
    char slot_flags{'4'};
    std::string url;
    std::string version;
    std::string software;
    std::string options;
};

enum class State {
    idle,
    waiting_login_ack,
    waiting_auth_ack,
    waiting_config_ack,
    waiting_options_ack,
    ready,
    backoff,
    stopped,
};

enum class Failure {
    none,
    invalid_profile,
    login_timeout,
    auth_timeout,
    config_timeout,
    options_timeout,
    pong_timeout,
    master_rejected,
    master_closed,
    malformed_response,
    unexpected_response,
    wrong_peer_id,
    authentication_error,
    inbound_queue_full,
    transport_lost,
    outbound_queue_full,
};

enum class PacketKind {
    control,
    keepalive,
    application,
};

struct OutboundDatagram {
    Endpoint target{};
    std::vector<std::uint8_t> bytes;
    PacketKind kind{PacketKind::control};
};

struct ApplicationDatagram {
    Endpoint source{};
    std::array<std::uint8_t, dmrd_datagram_size> bytes{};
};

enum class InputResult {
    accepted,
    application_datagram,
    ignored_wrong_endpoint,
    ignored_unknown_packet,
    rejected_wrong_state,
    rejected_malformed,
    rejected_application_queue_full,
    ignored_duplicate_ack,
    master_rejected,
    master_closed,
};

struct Snapshot {
    State state{State::idle};
    Failure last_failure{Failure::none};
    std::uint64_t next_action_at_ms{};
    std::size_t queued_outbound{};
    std::size_t queued_inbound{};
    std::uint32_t consecutive_failures{};
    bool rtt_valid{};
    std::uint64_t rtt_last_ms{};
    std::uint64_t rtt_sample_count{};
    std::uint64_t rtt_min_ms{};
    double rtt_avg_ms{};
    std::uint64_t rtt_max_ms{};
};

// 无 socket 的 Homebrew/MMDVM 登录和 DMRD 状态机；时间由调用方按单调毫秒传入。
class Session final {
public:
    Session() = default;
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;
    Session(Session&&) = delete;
    Session& operator=(Session&&) = delete;
    ~Session();

    // 接管运行期凭据；凭据保留到 stop() 或析构，以支持退避后重新登录。
    [[nodiscard]] bool start(Profile&& profile, const Endpoint& master, std::uint64_t now_ms);
    [[nodiscard]] InputResult on_datagram(const std::uint8_t* bytes,
                                          std::size_t size,
                                          const Endpoint& source,
                                          std::uint64_t now_ms);
    void tick(std::uint64_t now_ms);
    void transport_lost(std::uint64_t now_ms);
    void stop(std::uint64_t now_ms);

    // 仅在 UDP 发送接口确认成功后调用此方法。
    void record_outbound_sent(const OutboundDatagram& packet, std::uint64_t now_ms) noexcept;

    // 仅 ready 状态接受 DMRD；收发两侧都检查固定 55 字节帧。调用方负责经 UDP 收发结果。
    [[nodiscard]] bool send_dmrd(const std::uint8_t* bytes,
                                 std::size_t size,
                                 std::uint64_t now_ms);
    [[nodiscard]] std::optional<ApplicationDatagram> take_received_dmrd();
    [[nodiscard]] std::vector<OutboundDatagram> take_outbound();
    [[nodiscard]] Snapshot snapshot() const noexcept;

private:
    [[nodiscard]] bool validate_profile(const Profile& profile) const noexcept;
    [[nodiscard]] bool make_login_packet(std::vector<std::uint8_t>& packet) const;
    [[nodiscard]] bool make_auth_packet(const std::uint8_t* salt,
                                        std::vector<std::uint8_t>& packet);
    [[nodiscard]] bool make_config_packet(std::vector<std::uint8_t>& packet) const;
    [[nodiscard]] bool make_options_packet(std::vector<std::uint8_t>& packet) const;
    void begin_login(std::uint64_t now_ms);
    void set_waiting_state(State state, std::vector<std::uint8_t>&& packet, std::uint64_t now_ms);
    [[nodiscard]] bool queue_control(std::vector<std::uint8_t>&& packet);
    void enter_backoff(Failure failure, std::uint64_t now_ms);
    void clear_application_queues() noexcept;
    void clear_secret() noexcept;
    void clear_last_control_packet() noexcept;
    void clear_rtt() noexcept;
    [[nodiscard]] Failure timeout_failure() const noexcept;

    State state_{State::idle};
    Failure last_failure_{Failure::none};
    Endpoint master_{};
    Profile profile_{};
    std::string password_;
    std::vector<std::uint8_t> last_control_packet_;
    std::array<std::uint8_t, 4> challenge_salt_{};
    bool has_challenge_salt_{};
    std::deque<OutboundDatagram> outbound_;
    std::deque<ApplicationDatagram> inbound_;
    std::uint64_t phase_deadline_ms_{};
    std::uint64_t next_retry_ms_{};
    std::uint64_t retry_at_ms_{};
    std::uint64_t last_pong_ms_{};
    std::uint64_t next_ping_ms_{};
    bool rtt_pending_{};
    std::uint64_t rtt_sent_at_ms_{};
    std::uint64_t rtt_expires_at_ms_{};
    std::uint64_t rtt_last_ms_{};
    std::uint64_t rtt_sample_count_{};
    std::uint64_t rtt_min_ms_{};
    std::uint64_t rtt_max_ms_{};
    std::uint64_t rtt_sum_ms_{};
    std::uint32_t consecutive_failures_{};
};

} // 命名空间 wirex::bm
