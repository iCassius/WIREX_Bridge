#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>

#include "wirex/bm_udp.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>

namespace wirex::bm {
namespace {

constexpr std::uintptr_t invalid_socket_value = ~static_cast<std::uintptr_t>(0U);

SOCKET native_socket(std::uintptr_t value) noexcept
{
    return static_cast<SOCKET>(value);
}

sockaddr_in to_sockaddr(const Endpoint& endpoint) noexcept
{
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(endpoint.port);
    std::memcpy(&address.sin_addr.s_addr, endpoint.address.data(), endpoint.address.size());
    return address;
}

Endpoint from_sockaddr(const sockaddr_in& address) noexcept
{
    Endpoint endpoint{};
    std::memcpy(endpoint.address.data(), &address.sin_addr.s_addr, endpoint.address.size());
    endpoint.port = ntohs(address.sin_port);
    return endpoint;
}

} // 命名空间

UdpTransport::~UdpTransport()
{
    close();
}

bool UdpTransport::open(const Endpoint& master) noexcept
{
    close();
    if (master.port == 0U || master.address == std::array<std::uint8_t, 4>{{0U, 0U, 0U, 0U}}) {
        return false;
    }

    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
        return false;
    }
    winsock_started_ = true;

    const SOCKET socket_value = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_value == INVALID_SOCKET) {
        close();
        return false;
    }
    socket_handle_ = static_cast<std::uintptr_t>(socket_value);

    u_long nonblocking = 1UL;
    if (ioctlsocket(socket_value, FIONBIO, &nonblocking) == SOCKET_ERROR) {
        close();
        return false;
    }

    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = 0U;
    if (::bind(socket_value,
               reinterpret_cast<const sockaddr*>(&local),
               static_cast<int>(sizeof(local))) == SOCKET_ERROR) {
        close();
        return false;
    }

    master_ = master;
    return true;
}

bool UdpTransport::is_open() const noexcept
{
    return socket_handle_ != invalid_socket_value;
}

bool UdpTransport::send(const std::uint8_t* bytes, std::size_t size) noexcept
{
    if (!is_open() || bytes == nullptr || size == 0U || size > 65507U) {
        return false;
    }
    const auto address = to_sockaddr(master_);
    const int sent = sendto(native_socket(socket_handle_),
                            reinterpret_cast<const char*>(bytes),
                            static_cast<int>(size),
                            0,
                            reinterpret_cast<const sockaddr*>(&address),
                            static_cast<int>(sizeof(address)));
    return sent == static_cast<int>(size);
}

ReceiveResult UdpTransport::receive(std::uint32_t requested_wait_ms)
{
    ReceiveResult result{};
    if (!is_open()) {
        result.kind = ReceiveKind::closed;
        return result;
    }

    const auto bounded_wait = std::min(requested_wait_ms, max_wait_ms);
    fd_set readable{};
    FD_ZERO(&readable);
    FD_SET(native_socket(socket_handle_), &readable);
    timeval timeout{};
    timeout.tv_sec = static_cast<long>(bounded_wait / 1000U);
    timeout.tv_usec = static_cast<long>((bounded_wait % 1000U) * 1000U);
    const int selected = select(0, &readable, nullptr, nullptr, &timeout);
    if (selected == 0) {
        result.kind = ReceiveKind::timeout;
        return result;
    }
    if (selected == SOCKET_ERROR) {
        result.kind = ReceiveKind::socket_error;
        result.socket_error = WSAGetLastError();
        return result;
    }

    std::array<std::uint8_t, max_datagram_size> buffer{};
    sockaddr_in source{};
    int source_size = static_cast<int>(sizeof(source));
    const int received = recvfrom(native_socket(socket_handle_),
                                  reinterpret_cast<char*>(buffer.data()),
                                  static_cast<int>(buffer.size()),
                                  0,
                                  reinterpret_cast<sockaddr*>(&source),
                                  &source_size);
    if (received == SOCKET_ERROR) {
        result.socket_error = WSAGetLastError();
        result.kind = result.socket_error == WSAEMSGSIZE
                          ? ReceiveKind::oversized_datagram
                          : result.socket_error == WSAEWOULDBLOCK
                                ? ReceiveKind::timeout
                                : ReceiveKind::socket_error;
        if (result.kind == ReceiveKind::oversized_datagram &&
            source.sin_family == AF_INET &&
            source_size == static_cast<int>(sizeof(sockaddr_in))) {
            result.source = from_sockaddr(source);
        }
        return result;
    }
    if (source_size != static_cast<int>(sizeof(sockaddr_in)) || source.sin_family != AF_INET) {
        result.kind = ReceiveKind::socket_error;
        result.socket_error = WSAEINVAL;
        return result;
    }

    result.kind = ReceiveKind::datagram;
    result.source = from_sockaddr(source);
    result.bytes.assign(buffer.begin(), buffer.begin() + received);
    return result;
}

void UdpTransport::close() noexcept
{
    if (socket_handle_ != invalid_socket_value) {
        closesocket(native_socket(socket_handle_));
        socket_handle_ = invalid_socket_value;
    }
    master_ = {};
    if (winsock_started_) {
        WSACleanup();
        winsock_started_ = false;
    }
}

} // 命名空间 wirex::bm
