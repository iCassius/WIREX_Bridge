#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include "wirex/bm_connection_control.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <limits>
#include <new>
#include <string>
#include <string_view>
#include <utility>

namespace wirex::bm_connection {
namespace {

constexpr std::uint64_t resolve_timeout_ms = 3500U;
constexpr std::uint64_t cancel_warning_ms = 500U;

std::uint64_t after(std::uint64_t now_ms, std::uint64_t duration_ms) noexcept
{
    const auto max_value = std::numeric_limits<std::uint64_t>::max();
    return now_ms > max_value - duration_ms ? max_value : now_ms + duration_ms;
}

struct AddressLookup final {
    OVERLAPPED overlapped{};
    HANDLE event{};
    PADDRINFOEXW result{};
    HANDLE operation{};
    std::wstring host{};
    ADDRINFOEXW hints{};
    timeval timeout{};
    bool winsock_started{};
    bool cancel_requested{};
};

bool parse_ipv4_literal(std::string_view host, std::array<std::uint8_t, 4U>& address) noexcept
{
    if (host.empty() || host.size() > 15U) return false;
    std::array<char, 16U> text{};
    std::copy(host.begin(), host.end(), text.begin());
    IN_ADDR parsed{};
    if (InetPtonA(AF_INET, text.data(), &parsed) != 1) return false;
    std::memcpy(address.data(), &parsed, address.size());
    return true;
}

void erase_password(std::string& password) noexcept
{
    if (!password.empty()) SecureZeroMemory(password.data(), password.size());
    password.clear();
}

class SystemMasterResolver final : public MasterResolver {
public:
    SystemMasterResolver() = default;
    SystemMasterResolver(const SystemMasterResolver&) = delete;
    SystemMasterResolver& operator=(const SystemMasterResolver&) = delete;

    ~SystemMasterResolver() override
    {
        cancel();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{cancel_warning_ms};
        bm::Endpoint ignored{};
        while (lookup_ != nullptr && std::chrono::steady_clock::now() < deadline) {
            (void)poll(ignored);
            if (lookup_ != nullptr) Sleep(10U);
        }
        // DNS 提供程序若未完成取消，必须保留 OVERLAPPED 上下文直到进程退出。
        // 这唯一的操作仍挂起时，连接管理器拒绝启动新的查询。
        if (lookup_ != nullptr) (void)lookup_.release();
    }

    [[nodiscard]] ResolveResult start(std::string_view host, std::uint16_t port,
                                      bm::Endpoint& endpoint) noexcept override
    {
        if (lookup_ != nullptr || port == 0U) return ResolveResult::failed;
        endpoint = {};
        endpoint.port = port;
        if (parse_ipv4_literal(host, endpoint.address)) return ResolveResult::resolved;
        if (host.empty() || host.size() > 253U) return ResolveResult::failed;

        std::wstring wide_host;
        try {
            wide_host.reserve(host.size());
            for (const unsigned char ch : host) {
                if (ch <= 0x20U || ch >= 0x7fU) return ResolveResult::failed;
                wide_host.push_back(static_cast<wchar_t>(ch));
            }
        } catch (...) {
            return ResolveResult::failed;
        }

        WSADATA data{};
        if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return ResolveResult::failed;
        lookup_.reset(new (std::nothrow) AddressLookup{});
        if (lookup_ == nullptr) {
            WSACleanup();
            return ResolveResult::failed;
        }
        lookup_->winsock_started = true;
        lookup_->host = std::move(wide_host);
        lookup_->event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (lookup_->event == nullptr) {
            cleanup();
            return ResolveResult::failed;
        }
        lookup_->overlapped.hEvent = lookup_->event;
        lookup_->hints.ai_family = AF_INET;
        lookup_->hints.ai_socktype = SOCK_DGRAM;
        lookup_->hints.ai_protocol = IPPROTO_UDP;
        lookup_->timeout.tv_sec = 3;
        const INT started = GetAddrInfoExW(lookup_->host.c_str(), nullptr, NS_DNS, nullptr,
            &lookup_->hints, &lookup_->result, &lookup_->timeout, &lookup_->overlapped, nullptr,
            &lookup_->operation);
        if (started == WSA_IO_PENDING) return ResolveResult::pending;
        if (started == 0) {
            const bool resolved = copy_ipv4_result(endpoint);
            cleanup();
            return resolved ? ResolveResult::resolved : ResolveResult::failed;
        }
        cleanup();
        return ResolveResult::failed;
    }

    [[nodiscard]] ResolveResult poll(bm::Endpoint& endpoint) noexcept override
    {
        if (lookup_ == nullptr) return ResolveResult::failed;
        const DWORD waited = WaitForSingleObject(lookup_->event, 0U);
        if (waited == WAIT_TIMEOUT) return ResolveResult::pending;
        if (waited != WAIT_OBJECT_0) {
            cancel();
            return ResolveResult::pending;
        }
        const INT completion = GetAddrInfoExOverlappedResult(&lookup_->overlapped);
        const bool cancelled = lookup_->cancel_requested;
        const bool resolved = !cancelled && completion == 0 && copy_ipv4_result(endpoint);
        cleanup();
        if (cancelled) return ResolveResult::cancelled;
        return resolved ? ResolveResult::resolved : ResolveResult::failed;
    }

    void cancel() noexcept override
    {
        if (lookup_ == nullptr || lookup_->cancel_requested) return;
        lookup_->cancel_requested = true;
        if (lookup_->operation != nullptr) (void)GetAddrInfoExCancel(&lookup_->operation);
    }

    [[nodiscard]] bool pending() const noexcept override { return lookup_ != nullptr; }

private:
    [[nodiscard]] bool copy_ipv4_result(bm::Endpoint& endpoint) const noexcept
    {
        if (lookup_ == nullptr || lookup_->result == nullptr) return false;
        for (const auto* item = lookup_->result; item != nullptr; item = item->ai_next) {
            if (item->ai_family != AF_INET || item->ai_addr == nullptr ||
                item->ai_addrlen < sizeof(sockaddr_in)) continue;
            const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(item->ai_addr);
            std::memcpy(endpoint.address.data(), &ipv4->sin_addr, endpoint.address.size());
            return true;
        }
        return false;
    }

    void cleanup() noexcept
    {
        if (lookup_ == nullptr) return;
        if (lookup_->result != nullptr) FreeAddrInfoExW(lookup_->result);
        if (lookup_->event != nullptr) CloseHandle(lookup_->event);
        const bool winsock_started = lookup_->winsock_started;
        lookup_.reset();
        if (winsock_started) WSACleanup();
    }

    std::unique_ptr<AddressLookup> lookup_{};
};

} // namespace

std::unique_ptr<MasterResolver> make_system_master_resolver()
{
    return std::make_unique<SystemMasterResolver>();
}

const char* error_name(Error error) noexcept
{
    switch (error) {
    case Error::none: return "none";
    case Error::password_required: return "password_required";
    case Error::master_resolution_failed: return "master_resolution_failed";
    case Error::master_resolution_timeout: return "master_resolution_timeout";
    case Error::resolver_cancel_timeout: return "resolver_cancel_timeout";
    case Error::profile_invalid: return "profile_invalid";
    case Error::transport_open_failed: return "transport_open_failed";
    case Error::media_cleanup_timeout: return "media_cleanup_timeout";
    }
    return "none";
}

const char* request_error_name(RequestResult result) noexcept
{
    switch (result) {
    case RequestResult::accepted:
    case RequestResult::idempotent: return "";
    case RequestResult::stale_revision: return "bm_revision_stale";
    case RequestResult::revision_conflict: return "bm_revision_conflict";
    case RequestResult::transition_busy: return "bm_transition_busy";
    case RequestResult::password_required: return "bm_password_required";
    case RequestResult::master_resolution_failed: return "bm_master_resolution_failed";
    case RequestResult::profile_invalid: return "bm_profile_invalid";
    case RequestResult::transport_open_failed: return "bm_transport_open_failed";
    }
    return "bm_invalid_request";
}

ConnectionControl::ConnectionControl(bm::Profile profile, std::string master_host,
                                     std::uint16_t master_port,
                                     std::unique_ptr<MasterResolver> resolver)
    : profile_(std::move(profile)), master_host_(std::move(master_host)), master_port_(master_port),
      resolver_(resolver ? std::move(resolver) : make_system_master_resolver())
{
    session_.stop(0U);
}

ConnectionControl::~ConnectionControl()
{
    cancel_pending_resolution(0U);
    session_.stop(0U);
    transport_.close();
    erase_password(profile_.password);
}

bool ConnectionControl::start_initial_session(const bm::Endpoint& endpoint,
                                              std::uint64_t now_ms) noexcept
{
    if (requested_enabled_ || transport_.is_open() || endpoint.port == 0U ||
        endpoint.address == std::array<std::uint8_t, 4U>{{0U, 0U, 0U, 0U}} ||
        profile_.password.empty()) {
        error_ = profile_.password.empty() ? Error::password_required : Error::profile_invalid;
        return false;
    }
    bm::Profile candidate = profile_;
    if (!session_.start(std::move(candidate), endpoint, now_ms)) {
        error_ = Error::profile_invalid;
        return false;
    }
    initial_endpoint_ = endpoint;
    requested_enabled_ = true;
    revision_ = 0U;
    error_ = Error::none;
    return true;
}

bool ConnectionControl::open_initial_transport() noexcept
{
    if (!requested_enabled_ || initial_endpoint_.port == 0U) return false;
    if (transport_.is_open()) return true;
    if (!transport_.open(initial_endpoint_)) {
        session_.stop(0U);
        requested_enabled_ = false;
        error_ = Error::transport_open_failed;
        return false;
    }
    return true;
}

void ConnectionControl::abort_initial_startup(std::uint64_t now_ms) noexcept
{
    requested_enabled_ = false;
    resolving_ = false;
    disable_pending_ = false;
    stop_queued_ = false;
    session_.stop(now_ms);
    transport_.close();
}

RequestResult ConnectionControl::set_enabled(bool enabled, std::uint64_t revision,
                                              std::uint64_t now_ms) noexcept
{
    if (revision == 0U) return RequestResult::revision_conflict;
    if (revision < revision_) return RequestResult::stale_revision;
    if (revision == revision_) {
        if (!last_request_valid_ || enabled != last_request_enabled_) {
            return RequestResult::revision_conflict;
        }
        return last_request_result_ == RequestResult::accepted ||
            last_request_result_ == RequestResult::idempotent
            ? RequestResult::idempotent : last_request_result_;
    }

    if (!enabled) {
        revision_ = revision;
        last_request_valid_ = true;
        last_request_enabled_ = false;
        last_request_result_ = RequestResult::accepted;
        requested_enabled_ = false;
        resolving_ = false;
        error_ = Error::none;
        resolver_cleanup_pending_ = resolver_ && resolver_->pending();
        if (resolver_cleanup_pending_) {
            resolver_->cancel();
            resolver_cancel_deadline_ms_ = after(now_ms, cancel_warning_ms);
        }
        const auto state = session_.snapshot().state;
        disable_pending_ = transport_.is_open() ||
            (state != bm::State::idle && state != bm::State::stopped);
        return RequestResult::accepted;
    }

    if (disable_pending_ || stop_queued_) return RequestResult::transition_busy;
    if (resolver_cleanup_pending_ || (resolver_ && resolver_->pending())) {
        return RequestResult::transition_busy;
    }
    if (requested_enabled_) {
        revision_ = revision;
        if (resolving_) resolving_revision_ = revision;
        last_request_valid_ = true;
        last_request_enabled_ = true;
        last_request_result_ = RequestResult::accepted;
        error_ = Error::none;
        return RequestResult::accepted;
    }
    if (profile_.password.empty()) {
        revision_ = revision;
        last_request_valid_ = true;
        last_request_enabled_ = true;
        last_request_result_ = RequestResult::password_required;
        error_ = Error::password_required;
        return RequestResult::password_required;
    }

    bm::Endpoint endpoint{};
    const auto resolution = resolver_->start(master_host_, master_port_, endpoint);
    if (resolution == ResolveResult::failed || resolution == ResolveResult::cancelled) {
        revision_ = revision;
        last_request_valid_ = true;
        last_request_enabled_ = true;
        last_request_result_ = RequestResult::master_resolution_failed;
        error_ = Error::master_resolution_failed;
        return RequestResult::master_resolution_failed;
    }
    if (resolution == ResolveResult::resolved) {
        const auto started = start_resolved_session(endpoint, now_ms);
        revision_ = revision;
        last_request_valid_ = true;
        last_request_enabled_ = true;
        last_request_result_ = started;
        if (started == RequestResult::accepted) {
            requested_enabled_ = true;
            resolving_ = false;
            error_ = Error::none;
        }
        return started;
    }

    revision_ = revision;
    last_request_valid_ = true;
    last_request_enabled_ = true;
    last_request_result_ = RequestResult::accepted;
    requested_enabled_ = true;
    resolving_ = true;
    resolving_revision_ = revision;
    resolve_deadline_ms_ = after(now_ms, resolve_timeout_ms);
    error_ = Error::none;
    return RequestResult::accepted;
}

RequestResult ConnectionControl::start_resolved_session(const bm::Endpoint& endpoint,
                                                        std::uint64_t now_ms) noexcept
{
    if (profile_.password.empty()) {
        error_ = Error::password_required;
        return RequestResult::password_required;
    }
    bm::Profile candidate = profile_;
    if (!session_.start(std::move(candidate), endpoint, now_ms)) {
        error_ = Error::profile_invalid;
        return RequestResult::profile_invalid;
    }
    if (!transport_.open(endpoint)) {
        session_.stop(now_ms);
        error_ = Error::transport_open_failed;
        return RequestResult::transport_open_failed;
    }
    initial_endpoint_ = endpoint;
    return RequestResult::accepted;
}

void ConnectionControl::tick(std::uint64_t now_ms) noexcept
{
    poll_resolver(now_ms);
}

void ConnectionControl::poll_resolver(std::uint64_t now_ms) noexcept
{
    if (!resolver_ || !resolver_->pending()) {
        resolving_ = false;
        resolver_cleanup_pending_ = false;
        return;
    }

    if (resolving_ && now_ms >= resolve_deadline_ms_) {
        resolver_->cancel();
        resolving_ = false;
        resolver_cleanup_pending_ = resolver_->pending();
        resolver_cancel_deadline_ms_ = after(now_ms, cancel_warning_ms);
        requested_enabled_ = false;
        error_ = Error::master_resolution_timeout;
    }

    bm::Endpoint endpoint{};
    const auto result = resolver_->poll(endpoint);
    if (result == ResolveResult::pending) {
        if (resolver_cleanup_pending_ && now_ms >= resolver_cancel_deadline_ms_) {
            error_ = Error::resolver_cancel_timeout;
        }
        return;
    }

    const bool was_resolving = resolving_;
    if (result == ResolveResult::resolved) endpoint.port = master_port_;
    const bool may_start = was_resolving && requested_enabled_ && resolving_revision_ == revision_ &&
        result == ResolveResult::resolved;
    resolving_ = false;
    resolver_cleanup_pending_ = false;
    if (!was_resolving) return; // 取消或超时后的旧查询只回收上下文，不得启动会话。
    if (!may_start) {
        requested_enabled_ = false;
        if (error_ == Error::none) error_ = Error::master_resolution_failed;
        return;
    }

    const auto started = start_resolved_session(endpoint, now_ms);
    if (started != RequestResult::accepted) {
        requested_enabled_ = false;
        return;
    }
    error_ = Error::none;
}

bool ConnectionControl::begin_disable(std::uint64_t now_ms) noexcept
{
    if (!disable_pending_ || stop_queued_) return false;
    session_.stop(now_ms);
    stop_queued_ = true;
    return true;
}

void ConnectionControl::finish_disable() noexcept
{
    if (!stop_queued_) return;
    transport_.close();
    disable_pending_ = false;
    stop_queued_ = false;
}

void ConnectionControl::cancel_pending_resolution(std::uint64_t now_ms) noexcept
{
    if (!resolver_ || !resolver_->pending()) return;
    resolving_ = false;
    requested_enabled_ = false;
    resolver_cleanup_pending_ = true;
    resolver_cancel_deadline_ms_ = after(now_ms, cancel_warning_ms);
    resolver_->cancel();
}

Snapshot ConnectionControl::snapshot() const noexcept
{
    const auto current = session_.snapshot();
    return Snapshot{requested_enabled_, revision_, transport_.is_open(),
        resolving_ || resolver_cleanup_pending_ || (resolver_ && resolver_->pending()),
        current.state, error_};
}

} // namespace wirex::bm_connection
