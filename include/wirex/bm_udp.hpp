#pragma once

#include "wirex/bm_session.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wirex::bm {

enum class ReceiveKind {
    datagram,
    timeout,
    closed,
    oversized_datagram,
    socket_error,
};

struct ReceiveResult {
    ReceiveKind kind{ReceiveKind::closed};
    Endpoint source{};
    std::vector<std::uint8_t> bytes;
    int socket_error{};
};

// 使用 WinSock2 非阻塞 socket，并严格限制每次等待时长。
class UdpTransport final {
public:
    static constexpr std::uint32_t max_wait_ms = 100U;
    static constexpr std::uint32_t max_datagram_size = 2048U;

    UdpTransport() = default;
    UdpTransport(const UdpTransport&) = delete;
    UdpTransport& operator=(const UdpTransport&) = delete;
    UdpTransport(UdpTransport&&) = delete;
    UdpTransport& operator=(UdpTransport&&) = delete;
    ~UdpTransport();

    [[nodiscard]] bool open(const Endpoint& master) noexcept;
    [[nodiscard]] bool is_open() const noexcept;
    [[nodiscard]] bool send(const std::uint8_t* bytes, std::size_t size) noexcept;
    [[nodiscard]] ReceiveResult receive(std::uint32_t requested_wait_ms);
    void close() noexcept;

private:
    std::uintptr_t socket_handle_{~static_cast<std::uintptr_t>(0U)};
    Endpoint master_{};
    bool winsock_started_{};
};

} // 命名空间 wirex::bm
