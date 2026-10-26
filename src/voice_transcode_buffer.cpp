/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * YSF/DMR 语音静音常量和五槽/三码字分组来自：
 * Copyright (C) 2010, 2014, 2016 and 2018 Jonathan Naylor G4KLX
 * Copyright (C) 2016 Mathias Weyland, HB9FRV
 * Copyright (C) 2018 Andy Uribe CA6JAU
 * MMDVM_CM YSF2DMR/ModeConv.cpp, commit
 * 7328c9e9532d29cf4d9d7d24541d57f825207be4, GPL-2.0-or-later.
 * 本文件按 GPL-3.0-or-later 发布；对应许可与来源见 third_party/dmr_signal/NOTICE.md。
 */
#include "wirex/voice_transcode_buffer.hpp"

#include <algorithm>
#include <cstddef>

namespace wirex::voice_transcode {
namespace {

constexpr ambe2450::DmrCodeword kDmrSilence{{
    0xB9U, 0xE8U, 0x81U, 0x52U, 0x61U, 0x73U, 0x00U, 0x2AU, 0x6BU,
}};

constexpr ysf_vd2_vch::Vch kYsfSilence{{
    0x7BU, 0xB2U, 0x8EU, 0x43U, 0x36U, 0xE4U, 0xA2U,
    0x39U, 0x78U, 0x49U, 0x33U, 0x68U, 0x33U,
}};

} // namespace

BufferResult YsfToDmrBuffer::push(const YsfVchFrame& frame) noexcept
{
    if (input_closed_) {
        return BufferResult::input_closed;
    }
    if (voice_frame_capacity - count_ < frame.size()) {
        return BufferResult::full;
    }

    std::array<Item, ysf_vch_per_frame> converted{};
    for (std::size_t index = 0U; index < frame.size(); ++index) {
        const auto parameters = ysf_vd2_vch::decode_vch(frame[index]);
        if (!ambe2450::encode_dmr72(parameters, converted[index].codeword)) {
            return BufferResult::conversion_error;
        }
    }

    for (const auto& item : converted) {
        const std::size_t write = (read_ + count_) % items_.size();
        items_[write] = item;
        ++count_;
    }
    return BufferResult::accepted;
}

bool YsfToDmrBuffer::pop(
    dmr_call::AmbeVoiceBurst& burst,
    std::array<bool, dmr_codewords_per_burst>& padded) noexcept
{
    if (count_ < dmr_codewords_per_burst) {
        return false;
    }

    dmr_call::AmbeVoiceBurst next_burst{};
    std::array<bool, dmr_codewords_per_burst> next_padded{};
    for (std::size_t index = 0U; index < dmr_codewords_per_burst; ++index) {
        const auto& item = items_[(read_ + index) % items_.size()];
        const std::size_t offset = index * ambe2450::DmrCodeword{}.size();
        std::copy(item.codeword.begin(), item.codeword.end(),
                  next_burst.begin() + static_cast<std::ptrdiff_t>(offset));
        next_padded[index] = item.padded;
    }

    burst = next_burst;
    padded = next_padded;
    read_ = (read_ + dmr_codewords_per_burst) % items_.size();
    count_ -= dmr_codewords_per_burst;
    return true;
}

void YsfToDmrBuffer::finish() noexcept
{
    if (input_closed_) {
        return;
    }
    const std::size_t remainder = count_ % dmr_codewords_per_burst;
    const std::size_t padding = remainder == 0U ? 0U : dmr_codewords_per_burst - remainder;
    for (std::size_t index = 0U; index < padding; ++index) {
        const std::size_t write = (read_ + count_) % items_.size();
        items_[write] = Item{kDmrSilence, true};
        ++count_;
    }
    input_closed_ = true;
}

void YsfToDmrBuffer::reset() noexcept
{
    items_ = {};
    read_ = 0U;
    count_ = 0U;
    input_closed_ = false;
}

BufferResult DmrToYsfBuffer::push(const dmr_call::AmbeVoiceBurst& burst) noexcept
{
    if (input_closed_) {
        return BufferResult::input_closed;
    }
    if (voice_frame_capacity - count_ < dmr_codewords_per_burst) {
        return BufferResult::full;
    }

    std::array<Item, dmr_codewords_per_burst> converted{};
    for (std::size_t index = 0U; index < dmr_codewords_per_burst; ++index) {
        ambe2450::DmrCodeword codeword{};
        const std::size_t offset = index * codeword.size();
        std::copy_n(burst.begin() + static_cast<std::ptrdiff_t>(offset),
                    codeword.size(), codeword.begin());
        const auto decoded = ambe2450::decode_dmr72(codeword);
        if (!ysf_vd2_vch::encode_vch(decoded.parameters, converted[index].vch)) {
            return BufferResult::conversion_error;
        }
        converted[index].reencode_matches = decoded.reencode_matches;
        converted[index].padded = false;
    }

    for (const auto& item : converted) {
        const std::size_t write = (read_ + count_) % items_.size();
        items_[write] = item;
        ++count_;
    }
    return BufferResult::accepted;
}

bool DmrToYsfBuffer::pop(
    YsfVchFrame& frame,
    std::array<bool, ysf_vch_per_frame>& reencode_matches,
    std::array<bool, ysf_vch_per_frame>& padded) noexcept
{
    if (count_ < ysf_vch_per_frame) {
        return false;
    }

    YsfVchFrame next_frame{};
    std::array<bool, ysf_vch_per_frame> next_matches{};
    std::array<bool, ysf_vch_per_frame> next_padded{};
    for (std::size_t index = 0U; index < ysf_vch_per_frame; ++index) {
        const auto& item = items_[(read_ + index) % items_.size()];
        next_frame[index] = item.vch;
        next_matches[index] = item.reencode_matches;
        next_padded[index] = item.padded;
    }

    frame = next_frame;
    reencode_matches = next_matches;
    padded = next_padded;
    read_ = (read_ + ysf_vch_per_frame) % items_.size();
    count_ -= ysf_vch_per_frame;
    return true;
}

void DmrToYsfBuffer::finish() noexcept
{
    if (input_closed_) {
        return;
    }
    const std::size_t remainder = count_ % ysf_vch_per_frame;
    const std::size_t padding = remainder == 0U ? 0U : ysf_vch_per_frame - remainder;
    for (std::size_t index = 0U; index < padding; ++index) {
        const std::size_t write = (read_ + count_) % items_.size();
        // 合成静音没有原始 DMR 码字，reencode_matches=false 只作占位；padded=true 区分它。
        items_[write] = Item{kYsfSilence, false, true};
        ++count_;
    }
    input_closed_ = true;
}

void DmrToYsfBuffer::reset() noexcept
{
    items_ = {};
    read_ = 0U;
    count_ = 0U;
    input_closed_ = false;
}

} // namespace wirex::voice_transcode
