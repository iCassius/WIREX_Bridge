#pragma once

#include "wirex/ambe2450_parameters.hpp"

#include <array>
#include <cstdint>

namespace wirex::ambe2450 {

using DmrCodeword = std::array<std::uint8_t, 9U>;

struct DmrDecodeResult {
    Parameters parameters{};
    // 只表示按提取参数重新编码后，72 位是否逐位相同；不表示 CRC 通过或已纠错。
    bool reencode_matches{};
};

// 将有效的49位参数编码成包含DMR信道编码的9字节码字。参数无效时不修改输出。
[[nodiscard]] bool encode_dmr72(const Parameters& parameters, DmrCodeword& output) noexcept;

// 从9字节码字中提取Golay系统位和C字段，不执行纠错；保留错误码字对应的参数。
[[nodiscard]] DmrDecodeResult decode_dmr72(const DmrCodeword& codeword) noexcept;

} // namespace wirex::ambe2450
