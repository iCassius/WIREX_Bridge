#pragma once

// 引擎访问的设备边界（R128）。默认实现为 Windows 串口 + WinMM；离线测试注入假实现。
// 接口只覆盖引擎主循环实际使用的操作，失败原因字符串与 R127 status.jsonl 保持一致。

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace wirex::engine {

struct AudioEndpoints;

enum class SerialReadStatus : std::uint8_t {
    ok,               // received 可能为 0
    transport_error,  // 原 ClearCommError 失败或报告错误：serial_transport_error
    read_failed,      // 原 ReadFile 失败：serial_read_failed
};

class SerialPort {
public:
    virtual ~SerialPort() = default;
    // 完整写入一帧；短写或失败返回 false。
    [[nodiscard]] virtual bool write_all(const std::uint8_t* data, std::size_t size) noexcept = 0;
    // 非阻塞读取已到达的字节。
    [[nodiscard]] virtual SerialReadStatus read_available(std::uint8_t* buffer, std::size_t capacity,
                                                          std::size_t& received) noexcept = 0;
    // One-shot ownership transfer. false means CloseHandle/driver close was not confirmed;
    // callers must not retry on this wrapper because the native handle may already be invalid.
    [[nodiscard]] virtual bool close() noexcept = 0;
};

enum class CaptureStatus : std::uint8_t {
    ok,
    event_failed,   // 等待录音完成事件失败
    buffer_failed,  // 缓冲长度无效、sink 拒绝或重新排队失败
};

class AudioInput {
public:
    // 接收一块 48 kHz 单声道 PCM16；可原地修改样本（增益）。返回 false 视为该块失败。
    using Sink = std::function<bool(std::int16_t* samples, std::size_t count)>;

    virtual ~AudioInput() = default;
    [[nodiscard]] virtual bool open() noexcept = 0;   // 打开前核对 endpoint id
    [[nodiscard]] virtual bool is_open() const noexcept = 0;
    // 最多等待 wait_ms 后交付已录满的缓冲。requeue=false 为收尾排空：遇错继续处理其余缓冲。
    [[nodiscard]] virtual CaptureStatus take_captured(const Sink& sink, bool requeue,
                                                      std::uint32_t wait_ms) noexcept = 0;
    [[nodiscard]] virtual bool stop_capture() noexcept = 0;
    [[nodiscard]] virtual bool close() noexcept = 0;
};

class AudioOutput {
public:
    virtual ~AudioOutput() = default;
    [[nodiscard]] virtual bool open() noexcept = 0;   // 打开前核对 endpoint id
    [[nodiscard]] virtual bool is_open() const noexcept = 0;
    [[nodiscard]] virtual bool completion_overflowed() noexcept = 0;
    // 取出一组同 generation 的已播放 20 ms 帧计数。
    [[nodiscard]] virtual bool take_completed(std::uint64_t& generation, std::size_t& count) noexcept = 0;
    [[nodiscard]] virtual bool has_capacity() noexcept = 0;
    [[nodiscard]] virtual bool submit(const std::int16_t* samples, std::size_t count,
                                      std::uint64_t generation) noexcept = 0;
    [[nodiscard]] virtual bool all_drained() noexcept = 0;
    [[nodiscard]] virtual bool close() noexcept = 0;
};

class Devices {
public:
    virtual ~Devices() = default;
    // 读取并校验 HRI Y 模板（默认实现核对已批准的 SHA-256）。
    [[nodiscard]] virtual bool load_hri_template(const std::filesystem::path& path,
                                                 std::vector<std::uint8_t>& body) = 0;
    // R130 增补：AP PC 模式（中继开启）的 Y 模板，offset 0x05 为 '1'。Windows 实现核对 DIRECT/AP 两个固定哈希；
    // 默认实现（测试假设备）在 load_hri_template 成功后把 offset 0x05 改为 '1'。
    [[nodiscard]] virtual bool load_hri_template_ap(const std::filesystem::path& path,
                                                    std::vector<std::uint8_t>& body)
    {
        if (!load_hri_template(path, body) || body.size() <= 5U) return false;
        body[5] = '1';
        return true;
    }
    // 打开、配置并预排空 HRI 串口；失败时返回空并写入 R127 failure_reason。
    [[nodiscard]] virtual std::unique_ptr<SerialPort> open_serial(const std::wstring& port_name,
                                                                  std::string& failure_reason) = 0;
    // 创建（不打开）音频端点对象。
    [[nodiscard]] virtual std::unique_ptr<AudioInput> make_audio_input(const AudioEndpoints& endpoints) = 0;
    [[nodiscard]] virtual std::unique_ptr<AudioOutput> make_audio_output(const AudioEndpoints& endpoints) = 0;
};

// Windows 串口 + WinMM 实现（Engine() 默认使用）。
[[nodiscard]] std::shared_ptr<Devices> make_windows_devices();

} // namespace wirex::engine
