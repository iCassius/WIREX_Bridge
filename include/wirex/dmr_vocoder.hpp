#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

namespace wirex::dmr_vocoder {

inline constexpr std::size_t pcm_samples_per_frame = 160;
inline constexpr std::size_t codeword_bytes = 9;

using PcmFrame = std::array<std::int16_t, pcm_samples_per_frame>;

// 一个 DMR AMBE+2 2450x1150 语音码字：72 bit，包含信道 FEC。
// 它是 9 字节语音单元，不是 33 字节 DMR burst，也不是 49 bit 参数组。
using Codeword = std::array<std::uint8_t, codeword_bytes>;

// 状态按固定 commit 中 MBEVocoder 的 err_str 语义映射；FEC 状态不等同于 CRC。
enum class DecodeStatus : std::uint8_t {
    decoded,
    corrected,
    tone,
    concealed,
    erasure,
    muted_repeated_errors,
    invalid_parameters,
};

struct DecodeResult {
    PcmFrame pcm{};
    DecodeStatus status{DecodeStatus::erasure};
    std::uint32_t corrected_fec_bits{};
};

// 每条连续 TX 音频流使用独立编码器。对象会在 20 ms 帧之间保留声码器状态。
class Encoder final {
public:
    Encoder();
    ~Encoder();

    Encoder(const Encoder&) = delete;
    Encoder& operator=(const Encoder&) = delete;
    Encoder(Encoder&&) noexcept;
    Encoder& operator=(Encoder&&) noexcept;

    void reset();
    [[nodiscard]] Codeword encode(const PcmFrame& pcm);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// 每条连续 RX 音频流使用独立解码器；每次输入完整 9 字节码字。
// reset 会重建本实例的声码器历史。上游解码器用进程级 rand() 生成非浊音相位，
// 适配器会串行调用，但不同 RX 流仍会共同消耗该随机序列。
class Decoder final {
public:
    Decoder();
    ~Decoder();

    Decoder(const Decoder&) = delete;
    Decoder& operator=(const Decoder&) = delete;
    Decoder(Decoder&&) noexcept;
    Decoder& operator=(Decoder&&) noexcept;

    void reset();
    [[nodiscard]] DecodeResult decode(const Codeword& codeword);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace wirex::dmr_vocoder
