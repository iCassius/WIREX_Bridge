#include "wirex/hri_t_payload.hpp"

namespace wirex::hri_t_payload {

CandidateBody build_empty_header_empty_ambe_candidate_body(
    std::int32_t ptt_sw,
    std::int32_t field50,
    std::uint8_t flags248c) noexcept
{
    CandidateBody body{};
    body.fill(static_cast<std::uint8_t>('0'));

    if (ptt_sw != 1) {
        body[0] = static_cast<std::uint8_t>('0');
    } else if (field50 == 1) {
        body[0] = static_cast<std::uint8_t>('3');
    } else {
        body[0] = static_cast<std::uint8_t>((flags248c & 0x04U) != 0U ? '1' : '2');
    }

    body[7] = static_cast<std::uint8_t>('2');
    body[9] = static_cast<std::uint8_t>('1');
    body[10] = static_cast<std::uint8_t>('1');
    body[11] = static_cast<std::uint8_t>('4');

    body[80] = static_cast<std::uint8_t>('F');
    body[79] = static_cast<std::uint8_t>('1');
    for (std::size_t i = 81; i <= 85; ++i) {
        body[i] = static_cast<std::uint8_t>('*');
    }
    body[86] = static_cast<std::uint8_t>('3');
    body[87] = static_cast<std::uint8_t>('0');
    body[88] = static_cast<std::uint8_t>('3');
    body[89] = static_cast<std::uint8_t>('3');

    return body;
}

} // namespace wirex::hri_t_payload
