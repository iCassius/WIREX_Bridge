/* SPDX-License-Identifier: GPL-3.0-or-later
 * 固定容量的 YSF V/D2 VCH 与 DMR 2450x1150 码字分组缓冲。
 */
#pragma once

#include "wirex/ambe_dmr72.hpp"
#include "wirex/dmr_call.hpp"
#include "wirex/ysf_vd2_vch.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

namespace wirex::voice_transcode {

inline constexpr std::size_t voice_frame_capacity = 15U;
inline constexpr std::size_t ysf_vch_per_frame = 5U;
inline constexpr std::size_t dmr_codewords_per_burst = 3U;
static_assert(voice_frame_capacity % ysf_vch_per_frame == 0U &&
                  voice_frame_capacity % dmr_codewords_per_burst == 0U,
              "finish padding must fit either complete voice-frame group");

using YsfVchFrame = std::array<ysf_vd2_vch::Vch, ysf_vch_per_frame>;

enum class BufferResult : std::uint8_t {
    accepted,
    full,
    input_closed,
    conversion_error,
};

// 每组完整 YSF V/D2 VCH 转成 DMR 码字；本类不构造 DMRD 包或控制帧。
class YsfToDmrBuffer final {
public:
    [[nodiscard]] BufferResult push(const YsfVchFrame& frame) noexcept;
    // 只有至少三个码字时才弹出；padding 标志对应 burst 中的三个 9 字节码字。
    [[nodiscard]] bool pop(dmr_call::AmbeVoiceBurst& burst,
                           std::array<bool, dmr_codewords_per_burst>& padded) noexcept;

    // 停止接收输入，并在显式结束时补齐最后一个 DMR 语音 burst。
    void finish() noexcept;
    void reset() noexcept;

    [[nodiscard]] bool input_closed() const noexcept { return input_closed_; }
    [[nodiscard]] bool drained() const noexcept { return input_closed_ && count_ == 0U; }
    [[nodiscard]] std::size_t queued_frames() const noexcept { return count_; }

private:
    struct Item {
        ambe2450::DmrCodeword codeword{};
        bool padded{};
    };

    std::array<Item, voice_frame_capacity> items_{};
    std::size_t read_{};
    std::size_t count_{};
    bool input_closed_{};
};

// 每个 DMR burst 中的三个码字转为 VCH；本类不构造完整 YSF 射频/网络帧。
class DmrToYsfBuffer final {
public:
    [[nodiscard]] BufferResult push(const dmr_call::AmbeVoiceBurst& burst) noexcept;
    // 只有至少五个 VCH 时才弹出。
    // reencode_matches 仅对 padded[i] == false 的输入帧有诊断意义。
    [[nodiscard]] bool pop(YsfVchFrame& frame,
                           std::array<bool, ysf_vch_per_frame>& reencode_matches,
                           std::array<bool, ysf_vch_per_frame>& padded) noexcept;

    // 停止接收输入，并在显式结束时补齐最后一组五个 VCH。
    void finish() noexcept;
    void reset() noexcept;

    [[nodiscard]] bool input_closed() const noexcept { return input_closed_; }
    [[nodiscard]] bool drained() const noexcept { return input_closed_ && count_ == 0U; }
    [[nodiscard]] std::size_t queued_frames() const noexcept { return count_; }

private:
    struct Item {
        ysf_vd2_vch::Vch vch{};
        bool reencode_matches{};
        bool padded{};
    };

    std::array<Item, voice_frame_capacity> items_{};
    std::size_t read_{};
    std::size_t count_{};
    bool input_closed_{};
};

} // namespace wirex::voice_transcode
