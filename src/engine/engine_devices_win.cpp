// Devices 的 Windows 实现：串口与 WinMM 的具体调用沿用 R127 run_bm_bridge 中的序列。

#include "win_io.hpp"

#include "wirex/engine.hpp"
#include "wirex/engine_devices.hpp"

#include <algorithm>
#include <memory>
#include <string>

namespace wirex::engine {
namespace {

using win_io::WaveInput;
using win_io::WaveOutput;
using win_io::WinHandle;

class WindowsSerialPort final : public SerialPort {
public:
    explicit WindowsSerialPort(WinHandle handle) noexcept : handle_(std::move(handle)) {}

    bool write_all(const std::uint8_t* data, std::size_t size) noexcept override
    {
        if (!handle_.valid() || size > MAXDWORD) return false;
        DWORD written = 0U;
        const BOOL wrote = WriteFile(handle_.get(), data, static_cast<DWORD>(size), &written, nullptr);
        return wrote != FALSE && written == size;
    }

    SerialReadStatus read_available(std::uint8_t* buffer, std::size_t capacity,
                                    std::size_t& received) noexcept override
    {
        received = 0U;
        DWORD comm_errors = 0U;
        COMSTAT comm_state{};
        if (!ClearCommError(handle_.get(), &comm_errors, &comm_state) || comm_errors != 0U) {
            return SerialReadStatus::transport_error;
        }
        if (comm_state.cbInQue == 0U) return SerialReadStatus::ok;
        const DWORD wanted = std::min<DWORD>(comm_state.cbInQue,
            static_cast<DWORD>(std::min<std::size_t>(capacity, MAXDWORD)));
        DWORD actual = 0U;
        if (!ReadFile(handle_.get(), buffer, wanted, &actual, nullptr) || actual > wanted) {
            return SerialReadStatus::read_failed;
        }
        received = actual;
        return SerialReadStatus::ok;
    }

    bool close() noexcept override
    {
        const HANDLE raw = handle_.release();
        return raw == nullptr || raw == INVALID_HANDLE_VALUE || CloseHandle(raw) != FALSE;
    }

private:
    WinHandle handle_;
};

class WindowsAudioInput final : public AudioInput {
public:
    WindowsAudioInput(unsigned device_id, std::wstring endpoint_id)
        : device_id_(device_id), endpoint_id_(std::move(endpoint_id)) {}

    bool open() noexcept override { return input_.open(device_id_, &endpoint_id_); }
    bool is_open() const noexcept override { return input_.is_open(); }
    bool stop_capture() noexcept override { return input_.stop_capture(); }
    bool close() noexcept override { return input_.close(); }

    // 原 consume_tx_wave_buffer + 轮询循环：遍历已完成缓冲，交付 PCM，按需重新排队或擦除。
    CaptureStatus take_captured(const Sink& sink, bool requeue, std::uint32_t wait_ms) noexcept override
    {
        const DWORD wait_result = WaitForSingleObject(input_.event(), wait_ms);
        // 运行中等待失败立即上报；收尾排空时仍消费已完成缓冲，仅把结果记为失败（与 R127 一致）。
        if (wait_result == WAIT_FAILED && requeue) return CaptureStatus::event_failed;
        bool all_ok = wait_result != WAIT_FAILED;
        for (auto& buffer : input_.buffers()) {
            if ((buffer.header.dwFlags & WHDR_DONE) == 0U) continue;
            const DWORD bytes = buffer.header.dwBytesRecorded;
            bool succeeded = bytes <= buffer.header.dwBufferLength && bytes % sizeof(std::int16_t) == 0U;
            if (succeeded) {
                const auto samples = static_cast<std::size_t>(bytes / sizeof(std::int16_t));
                try { succeeded = sink(buffer.samples.data(), samples); } catch (...) { succeeded = false; }
            }
            buffer.header.dwBytesRecorded = 0U;
            if (requeue && succeeded) {
                if (input_.requeue(buffer) != MMSYSERR_NOERROR) return CaptureStatus::buffer_failed;
                continue;
            }
            win_io::secure_wipe(buffer.samples.data(), sizeof(buffer.samples));
            if (!succeeded) {
                if (requeue) return CaptureStatus::buffer_failed;
                all_ok = false;
            }
        }
        return all_ok ? CaptureStatus::ok : CaptureStatus::buffer_failed;
    }

private:
    unsigned device_id_;
    std::wstring endpoint_id_;
    WaveInput input_{};
};

class WindowsAudioOutput final : public AudioOutput {
public:
    WindowsAudioOutput(unsigned device_id, std::wstring endpoint_id)
        : device_id_(device_id), endpoint_id_(std::move(endpoint_id)) {}

    bool open() noexcept override
    {
        try { return output_.open(device_id_, &endpoint_id_); } catch (...) { return false; }
    }
    bool is_open() const noexcept override { return output_.is_open(); }
    bool completion_overflowed() noexcept override
    {
        output_.reap();
        return output_.completion_overflowed();
    }
    bool take_completed(std::uint64_t& generation, std::size_t& count) noexcept override
    {
        WaveOutput::CompletedFrames completed{};
        if (!output_.take_completed_frames(completed)) return false;
        generation = completed.generation;
        count = completed.count;
        return true;
    }
    bool has_capacity() noexcept override { return output_.has_capacity(); }
    bool submit(const std::int16_t* samples, std::size_t count, std::uint64_t generation) noexcept override
    {
        const auto byte_count = static_cast<DWORD>(count * sizeof(std::int16_t));
        return output_.submit_playback_frame(samples, byte_count, generation) == WaveOutput::SubmitResult::queued;
    }
    bool all_drained() noexcept override { return output_.all_drained(); }
    bool close() noexcept override { return output_.close(); }

private:
    unsigned device_id_;
    std::wstring endpoint_id_;
    WaveOutput output_{};
};

class WindowsDevices final : public Devices {
public:
    bool load_hri_template(const std::filesystem::path& path, std::vector<std::uint8_t>& body) override
    {
        return win_io::load_hri_y_template(path, body);
    }

    std::unique_ptr<SerialPort> open_serial(const std::wstring& port_name, std::string& failure_reason) override
    {
        std::wstring device_path;
        if (!win_io::parse_port(port_name, device_path)) {
            failure_reason = "port_name_invalid";
            return nullptr;
        }
        WinHandle port(CreateFileW(device_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
        if (!port.valid() || !win_io::configure_serial(port.get(), false)) {
            failure_reason = "serial_open_or_configure_failed";
            return nullptr;
        }
        COMMTIMEOUTS timeouts{};
        timeouts.ReadIntervalTimeout = 5U;
        timeouts.ReadTotalTimeoutConstant = 10U;
        timeouts.WriteTotalTimeoutConstant = 100U;
        if (!SetCommTimeouts(port.get(), &timeouts)) {
            failure_reason = "serial_timeout_config_failed";
            return nullptr;
        }
        std::uint64_t discarded_serial_bytes = 0U;
        if (!win_io::pre_drain_hri_serial(port.get(), discarded_serial_bytes)) {
            failure_reason = "serial_pre_drain_failed";
            return nullptr;
        }
        return std::make_unique<WindowsSerialPort>(std::move(port));
    }

    std::unique_ptr<AudioInput> make_audio_input(const AudioEndpoints& endpoints) override
    {
        return std::make_unique<WindowsAudioInput>(endpoints.wave_in_id, endpoints.expected_wave_in_endpoint_id);
    }

    std::unique_ptr<AudioOutput> make_audio_output(const AudioEndpoints& endpoints) override
    {
        return std::make_unique<WindowsAudioOutput>(endpoints.wave_out_id, endpoints.expected_wave_out_endpoint_id);
    }
};

} // namespace

std::shared_ptr<Devices> make_windows_devices()
{
    return std::make_shared<WindowsDevices>();
}

} // namespace wirex::engine
