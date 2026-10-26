#include "wirex/voice_transcode_buffer.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace {

using wirex::ambe2450::DmrCodeword;
using wirex::dmr_call::AmbeVoiceBurst;
using wirex::voice_transcode::BufferResult;
using wirex::voice_transcode::DmrToYsfBuffer;
using wirex::voice_transcode::YsfToDmrBuffer;
using wirex::voice_transcode::YsfVchFrame;
using wirex::ysf_vd2_vch::Vch;

int failures = 0;

void check(bool condition, const char* label)
{
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", label);
        ++failures;
    }
}

template <typename T, std::size_t N>
void check_equal(const std::array<T, N>& actual,
                 const std::array<T, N>& expected,
                 const char* label)
{
    if (actual != expected) {
        std::fprintf(stderr, "FAIL: %s\n", label);
        ++failures;
    }
}

// 来自固定映射单测的独立 VCH fixture，包含边界与交错数据。
constexpr std::array<Vch, 5U> kVchVectors{{
    Vch{{0xF3U, 0x19U, 0x37U, 0xDAU, 0x8CU, 0x4CU, 0x3BU,
         0xB9U, 0x6BU, 0x7FU, 0x55U, 0x0CU, 0x63U}},
    Vch{{0x0CU, 0xE6U, 0xC8U, 0x25U, 0x73U, 0xB3U, 0xC4U,
         0x46U, 0x94U, 0x80U, 0xAAU, 0xF3U, 0x9DU}},
    Vch{{0x08U, 0x89U, 0x61U, 0x20U, 0x1CU, 0x5EU, 0x85U,
         0x6DU, 0x79U, 0xC1U, 0xA3U, 0x3CU, 0xFFU}},
    Vch{{0x7BU, 0x99U, 0x37U, 0xDAU, 0x8CU, 0x4CU, 0x3BU,
         0xB9U, 0x69U, 0x5DU, 0x77U, 0x2CU, 0x73U}},
    Vch{{0x7BU, 0xB2U, 0x8EU, 0x43U, 0x36U, 0xE4U, 0xA2U,
         0x39U, 0x78U, 0x49U, 0x33U, 0x68U, 0x33U}},
}};

// 来自 ambe_dmr72_test.cpp 的固定 MBE 向量以及 MMDVM_CM DMR_SILENCE。
constexpr std::array<DmrCodeword, 9U> kDmrCodewords{{
    DmrCodeword{{0xD5U, 0xEEU, 0x22U, 0x07U, 0x41U, 0xB9U, 0x68U, 0x0BU, 0x2FU}},
    DmrCodeword{{0xD5U, 0x6FU, 0x66U, 0x63U, 0x40U, 0xB5U, 0x00U, 0xA3U, 0xFBU}},
    DmrCodeword{{0x0EU, 0xE8U, 0x06U, 0x72U, 0x03U, 0x81U, 0x38U, 0x8FU, 0xEFU}},
    DmrCodeword{{0x7DU, 0x08U, 0x04U, 0x31U, 0x65U, 0xF1U, 0xE1U, 0x67U, 0xE7U}},
    DmrCodeword{{0x40U, 0x9AU, 0x40U, 0x73U, 0x76U, 0x90U, 0x25U, 0x6AU, 0xABU}},
    DmrCodeword{{0x15U, 0x86U, 0x60U, 0x67U, 0x47U, 0xB1U, 0x4CU, 0x82U, 0x6FU}},
    DmrCodeword{{0x66U, 0x44U, 0x62U, 0x43U, 0x50U, 0xF1U, 0xC0U, 0x4CU, 0x05U}},
    DmrCodeword{{0x46U, 0x44U, 0x60U, 0x22U, 0x04U, 0xC5U, 0x94U, 0x0CU, 0x45U}},
    DmrCodeword{{0xB9U, 0xE8U, 0x81U, 0x52U, 0x61U, 0x73U, 0x00U, 0x2AU, 0x6BU}},
}};

constexpr DmrCodeword kDmrSilence{{
    0xB9U, 0xE8U, 0x81U, 0x52U, 0x61U, 0x73U, 0x00U, 0x2AU, 0x6BU,
}};
constexpr Vch kYsfSilence{{
    0x7BU, 0xB2U, 0x8EU, 0x43U, 0x36U, 0xE4U, 0xA2U,
    0x39U, 0x78U, 0x49U, 0x33U, 0x68U, 0x33U,
}};

YsfVchFrame make_ysf_frame(std::size_t first_vector)
{
    YsfVchFrame frame{};
    for (std::size_t index = 0U; index < frame.size(); ++index) {
        frame[index] = kVchVectors[(first_vector + index) % kVchVectors.size()];
    }
    return frame;
}

AmbeVoiceBurst make_dmr_burst(std::size_t first_codeword)
{
    AmbeVoiceBurst burst{};
    for (std::size_t index = 0U; index < wirex::dmr_call::codewords_per_burst; ++index) {
        const auto& codeword = kDmrCodewords[(first_codeword + index) % kDmrCodewords.size()];
        const std::size_t offset = index * codeword.size();
        for (std::size_t byte = 0U; byte < codeword.size(); ++byte) {
            burst[offset + byte] = codeword[byte];
        }
    }
    return burst;
}

DmrCodeword vch_to_dmr(const Vch& vch)
{
    DmrCodeword result{};
    const auto parameters = wirex::ysf_vd2_vch::decode_vch(vch);
    check(wirex::ambe2450::encode_dmr72(parameters, result), "fixed VCH parameters encode to DMR");
    return result;
}

Vch dmr_to_vch(const DmrCodeword& codeword, bool* reencode_matches = nullptr)
{
    const auto decoded = wirex::ambe2450::decode_dmr72(codeword);
    if (reencode_matches != nullptr) {
        *reencode_matches = decoded.reencode_matches;
    }
    Vch result{};
    check(wirex::ysf_vd2_vch::encode_vch(decoded.parameters, result),
          "fixed DMR parameters encode to VCH");
    return result;
}

void check_burst_codewords(const AmbeVoiceBurst& burst,
                           const std::array<DmrCodeword, 3U>& expected,
                           const char* label)
{
    for (std::size_t index = 0U; index < expected.size(); ++index) {
        DmrCodeword actual{};
        const std::size_t offset = index * actual.size();
        for (std::size_t byte = 0U; byte < actual.size(); ++byte) {
            actual[byte] = burst[offset + byte];
        }
        check_equal(actual, expected[index], label);
    }
}

void test_ysf_to_dmr_order_and_atomic_capacity()
{
    YsfToDmrBuffer buffer;
    std::array<DmrCodeword, 15U> expected{};
    for (std::size_t frame_index = 0U; frame_index < 3U; ++frame_index) {
        const auto frame = make_ysf_frame(frame_index);
        check(buffer.push(frame) == BufferResult::accepted, "accept a complete five-VCH YSF frame");
        for (std::size_t index = 0U; index < frame.size(); ++index) {
            expected[frame_index * frame.size() + index] = vch_to_dmr(frame[index]);
        }
    }
    check(buffer.queued_frames() == 15U, "three YSF frames fill the fixed fifteen-frame buffer");
    check(buffer.push(make_ysf_frame(2U)) == BufferResult::full,
          "a full YSF input buffer rejects the whole next frame");
    check(buffer.queued_frames() == 15U, "rejected YSF frame leaves the buffer unchanged");

    for (std::size_t burst_index = 0U; burst_index < 5U; ++burst_index) {
        AmbeVoiceBurst actual{};
        std::array<bool, 3U> padded{{true, true, true}};
        check(buffer.pop(actual, padded), "pop complete three-codeword DMR burst");
        std::array<DmrCodeword, 3U> expected_burst{};
        for (std::size_t index = 0U; index < expected_burst.size(); ++index) {
            expected_burst[index] = expected[burst_index * expected_burst.size() + index];
        }
        check_burst_codewords(actual, expected_burst, "DMR codewords preserve input VCH order");
        check(padded == std::array<bool, 3U>{{false, false, false}},
              "ordinary DMR bursts have no padding markers");
    }
    check(buffer.queued_frames() == 0U && !buffer.drained(),
          "an open empty buffer is not a finished/drained call");
}

void test_ysf_to_dmr_finish_padding_and_reset()
{
    for (std::size_t frame_count = 0U; frame_count <= 2U; ++frame_count) {
        YsfToDmrBuffer buffer;
        std::array<DmrCodeword, 10U> expected{};
        for (std::size_t frame_index = 0U; frame_index < frame_count; ++frame_index) {
            const auto frame = make_ysf_frame(frame_index);
            check(buffer.push(frame) == BufferResult::accepted, "accept YSF input before finish");
            for (std::size_t index = 0U; index < frame.size(); ++index) {
                expected[frame_index * frame.size() + index] = vch_to_dmr(frame[index]);
            }
        }

        AmbeVoiceBurst popped{};
        std::array<bool, 3U> popped_padding{};
        while (buffer.pop(popped, popped_padding)) {
        }
        const std::size_t real_remaining = (frame_count * 5U) % 3U;
        check(buffer.queued_frames() == real_remaining, "pre-finish bursts leave only a partial burst");

        buffer.finish();
        const std::size_t finished_count = real_remaining == 0U ? 0U : 3U;
        check(buffer.input_closed(), "finish closes YSF input");
        check(buffer.queued_frames() == finished_count, "finish pads to a complete DMR burst");
        const auto count_after_finish = buffer.queued_frames();
        buffer.finish();
        check(buffer.queued_frames() == count_after_finish, "repeated finish is idempotent");
        check(buffer.push(make_ysf_frame(4U)) == BufferResult::input_closed,
              "finished YSF buffer rejects further input");

        if (real_remaining == 0U) {
            check(buffer.drained(), "empty finished YSF buffer is drained");
            continue;
        }

        check(!buffer.drained(), "padded DMR burst must drain before the call can end");
        AmbeVoiceBurst final_burst{};
        std::array<bool, 3U> padded{};
        check(buffer.pop(final_burst, padded), "finish exposes the final padded DMR burst");
        const std::size_t total_real = frame_count * 5U;
        std::array<DmrCodeword, 3U> expected_last{};
        for (std::size_t index = 0U; index < real_remaining; ++index) {
            expected_last[index] = expected[total_real - real_remaining + index];
        }
        for (std::size_t index = real_remaining; index < expected_last.size(); ++index) {
            expected_last[index] = kDmrSilence;
        }
        check_burst_codewords(final_burst, expected_last, "DMR EOT padding uses fixed silence after real frames");
        for (std::size_t index = 0U; index < padded.size(); ++index) {
            check(padded[index] == (index >= real_remaining),
                  "DMR padding marker distinguishes real codewords from silence");
        }
        check(buffer.drained(), "buffer becomes drained after its final burst is popped");
    }

    YsfToDmrBuffer reset_buffer;
    check(reset_buffer.push(make_ysf_frame(0U)) == BufferResult::accepted,
          "reset test accepts first YSF frame");
    AmbeVoiceBurst discarded{};
    std::array<bool, 3U> discarded_padding{};
    check(reset_buffer.pop(discarded, discarded_padding), "reset test removes first burst");
    check(reset_buffer.queued_frames() == 2U, "reset test leaves a partial old burst");
    reset_buffer.finish();
    reset_buffer.reset();
    check(!reset_buffer.input_closed() && reset_buffer.queued_frames() == 0U &&
              !reset_buffer.drained(),
          "reset discards old-call tail and reopens input");
    const auto next_frame = make_ysf_frame(3U);
    check(reset_buffer.push(next_frame) == BufferResult::accepted, "new call accepts a fresh YSF frame");
    AmbeVoiceBurst next_burst{};
    std::array<bool, 3U> next_padding{{true, true, true}};
    check(reset_buffer.pop(next_burst, next_padding), "new call returns its own first burst");
    const std::array<DmrCodeword, 3U> expected_next{{
        vch_to_dmr(next_frame[0U]), vch_to_dmr(next_frame[1U]), vch_to_dmr(next_frame[2U]),
    }};
    check_burst_codewords(next_burst, expected_next, "reset prevents old-call frames crossing into next call");
    check(next_padding == std::array<bool, 3U>{{false, false, false}},
          "new-call frames are not marked as padding");
}

void test_ysf_pop_leaves_outputs_untouched_when_incomplete()
{
    YsfToDmrBuffer buffer;
    check(buffer.push(make_ysf_frame(0U)) == BufferResult::accepted,
          "incomplete-pop fixture accepts one YSF frame");
    AmbeVoiceBurst first{};
    std::array<bool, 3U> flags{};
    check(buffer.pop(first, flags), "incomplete-pop fixture removes one DMR burst");

    AmbeVoiceBurst output{};
    output.fill(0xA5U);
    std::array<bool, 3U> padding{{true, false, true}};
    const auto original_output = output;
    const auto original_padding = padding;
    check(!buffer.pop(output, padding), "two queued codewords do not form a DMR burst");
    check_equal(output, original_output, "incomplete DMR pop leaves output bytes unchanged");
    check(padding == original_padding, "incomplete DMR pop leaves padding output unchanged");
}

void test_dmr_to_ysf_order_and_atomic_capacity()
{
    DmrToYsfBuffer buffer;
    std::array<Vch, 15U> expected{};
    std::array<bool, 15U> expected_matches{};
    for (std::size_t burst_index = 0U; burst_index < 5U; ++burst_index) {
        const auto burst = make_dmr_burst(burst_index * 3U);
        check(buffer.push(burst) == BufferResult::accepted, "accept a complete three-codeword DMR burst");
        for (std::size_t index = 0U; index < 3U; ++index) {
            DmrCodeword codeword{};
            for (std::size_t byte = 0U; byte < codeword.size(); ++byte) {
                codeword[byte] = burst[index * codeword.size() + byte];
            }
            bool reencode_matches = false;
            expected[burst_index * 3U + index] = dmr_to_vch(codeword, &reencode_matches);
            expected_matches[burst_index * 3U + index] = reencode_matches;
        }
    }
    check(buffer.queued_frames() == 15U, "five DMR bursts fill the fixed fifteen-frame buffer");
    check(buffer.push(make_dmr_burst(0U)) == BufferResult::full,
          "a full DMR input buffer rejects the whole next burst");
    check(buffer.queued_frames() == 15U, "rejected DMR burst leaves the buffer unchanged");

    for (std::size_t frame_index = 0U; frame_index < 3U; ++frame_index) {
        YsfVchFrame actual{};
        std::array<bool, 5U> matches{};
        std::array<bool, 5U> padded{{true, true, true, true, true}};
        check(buffer.pop(actual, matches, padded), "pop complete five-VCH YSF frame");
        for (std::size_t index = 0U; index < actual.size(); ++index) {
            const std::size_t source_index = frame_index * actual.size() + index;
            check_equal(actual[index], expected[source_index], "YSF VCH frames preserve DMR codeword order");
            check(matches[index] == expected_matches[source_index],
                  "per-codeword re-encode diagnostic follows its corresponding VCH");
        }
        check(padded == std::array<bool, 5U>{{false, false, false, false, false}},
              "ordinary YSF frames have no padding markers");
    }
    check(buffer.queued_frames() == 0U && !buffer.drained(),
          "an open empty reverse buffer is not a finished/drained call");
}

void test_dmr_to_ysf_finish_padding_and_reset()
{
    // 3*n mod 5 遍历全部五种结束余数；所有输入均为固定 DMR_SILENCE 向量。
    constexpr std::array<std::size_t, 5U> burst_counts{{0U, 2U, 4U, 1U, 3U}};
    for (std::size_t remainder = 0U; remainder < burst_counts.size(); ++remainder) {
        DmrToYsfBuffer buffer;
        std::array<Vch, 12U> expected{};
        const auto silence_burst = make_dmr_burst(8U);
        const std::size_t input_bursts = burst_counts[remainder];
        std::size_t expected_count = 0U;
        for (std::size_t burst_index = 0U; burst_index < input_bursts; ++burst_index) {
            check(buffer.push(silence_burst) == BufferResult::accepted,
                  "accept fixed DMR silence burst before finish");
            for (std::size_t index = 0U; index < 3U; ++index) {
                DmrCodeword codeword{};
                for (std::size_t byte = 0U; byte < codeword.size(); ++byte) {
                    codeword[byte] = silence_burst[index * codeword.size() + byte];
                }
                expected[expected_count++] = dmr_to_vch(codeword);
            }
        }

        YsfVchFrame drained_frame{};
        std::array<bool, 5U> drained_matches{};
        std::array<bool, 5U> drained_padding{};
        std::size_t popped_frames = 0U;
        while (buffer.pop(drained_frame, drained_matches, drained_padding)) {
            ++popped_frames;
        }
        const std::size_t real_remaining = expected_count - popped_frames * 5U;
        check(real_remaining == remainder, "test setup reaches each reverse-direction end remainder");
        check(buffer.queued_frames() == real_remaining, "pre-finish YSF frames leave the expected partial group");

        buffer.finish();
        const std::size_t finished_count = real_remaining == 0U ? 0U : 5U;
        check(buffer.input_closed(), "finish closes DMR input");
        check(buffer.queued_frames() == finished_count, "finish pads to a complete five-VCH frame");
        const auto count_after_finish = buffer.queued_frames();
        buffer.finish();
        check(buffer.queued_frames() == count_after_finish, "repeated reverse finish is idempotent");
        check(buffer.push(silence_burst) == BufferResult::input_closed,
              "finished reverse buffer rejects further input");

        if (real_remaining == 0U) {
            check(buffer.drained(), "empty finished reverse buffer is drained");
            continue;
        }

        check(!buffer.drained(), "padded YSF frame must drain before call end");
        YsfVchFrame final_frame{};
        std::array<bool, 5U> matches{};
        std::array<bool, 5U> padded{};
        check(buffer.pop(final_frame, matches, padded), "finish exposes final padded YSF frame");
        for (std::size_t index = 0U; index < 5U; ++index) {
            if (index < real_remaining) {
                check_equal(final_frame[index], expected[expected_count - real_remaining + index],
                            "real reverse-converted VCHs remain before silence padding");
                check(matches[index], "fixed DMR silence input re-encodes exactly");
                check(!padded[index], "received DMR frame is not marked as padding");
            } else {
                check_equal(final_frame[index], kYsfSilence, "reverse EOT padding uses fixed YSF silence");
                check(!matches[index], "synthetic YSF silence has no re-encode match claim");
                check(padded[index], "synthetic YSF silence is marked as padding");
            }
        }
        check(buffer.drained(), "reverse buffer becomes drained after its last YSF frame");
    }

    DmrToYsfBuffer reset_buffer;
    const auto old_burst = make_dmr_burst(0U);
    check(reset_buffer.push(old_burst) == BufferResult::accepted, "reverse reset fixture accepts old burst");
    reset_buffer.finish();
    check(reset_buffer.queued_frames() == 5U, "old partial DMR burst pads before reset");
    reset_buffer.reset();
    check(!reset_buffer.input_closed() && reset_buffer.queued_frames() == 0U &&
              !reset_buffer.drained(),
          "reverse reset clears old-call frames and opens input");
    check(reset_buffer.push(make_dmr_burst(8U)) == BufferResult::accepted,
          "new reverse call accepts a fresh DMR burst");
    check(reset_buffer.queued_frames() == 3U, "new call contains only its three input codewords");
}

void test_dmr_reencode_diagnostic_and_incomplete_pop()
{
    auto damaged_silence = kDmrSilence;
    damaged_silence[6U] ^= 0x80U;
    const auto damaged_burst = [&damaged_silence]() {
        AmbeVoiceBurst burst{};
        for (std::size_t index = 0U; index < 3U; ++index) {
            const auto& word = index == 0U ? damaged_silence : kDmrSilence;
            for (std::size_t byte = 0U; byte < word.size(); ++byte) {
                burst[index * word.size() + byte] = word[byte];
            }
        }
        return burst;
    }();

    DmrToYsfBuffer buffer;
    check(buffer.push(damaged_burst) == BufferResult::accepted, "accept a fixed-width DMR burst with parity damage");
    YsfVchFrame output{};
    for (auto& vch : output) {
        vch.fill(0xA5U);
    }
    std::array<bool, 5U> matches{{true, false, true, false, true}};
    std::array<bool, 5U> padded{{false, true, false, true, false}};
    const auto old_output = output;
    const auto old_matches = matches;
    const auto old_padded = padded;
    check(!buffer.pop(output, matches, padded), "three VCHs do not form a five-VCH output frame");
    check(output == old_output && matches == old_matches && padded == old_padded,
          "incomplete YSF pop leaves every output unchanged");

    check(buffer.push(make_dmr_burst(8U)) == BufferResult::accepted,
          "a second DMR burst completes the pending YSF frame");
    check(buffer.pop(output, matches, padded), "completed five-VCH frame is available");
    check(!matches[0U] && matches[1U] && matches[2U] && matches[3U] && matches[4U],
          "parity re-encode mismatch stays attached to its input frame");
    check(padded == std::array<bool, 5U>{{false, false, false, false, false}},
          "parity mismatch is distinct from synthetic padding");
}

} // namespace

int main()
{
    test_ysf_to_dmr_order_and_atomic_capacity();
    test_ysf_to_dmr_finish_padding_and_reset();
    test_ysf_pop_leaves_outputs_untouched_when_incomplete();
    test_dmr_to_ysf_order_and_atomic_capacity();
    test_dmr_to_ysf_finish_padding_and_reset();
    test_dmr_reencode_diagnostic_and_incomplete_pop();

    if (failures != 0) {
        std::fprintf(stderr, "%d voice transcode buffer check(s) failed.\n", failures);
        return EXIT_FAILURE;
    }
    std::puts("Voice transcode fixed-capacity, ordering, padding, and reset checks passed.");
    return EXIT_SUCCESS;
}
