#include "wirex/ysf_vd2_vch.hpp"

#include <array>
#include <cstdio>
#include <cstdlib>
#include <iostream>

namespace {

using wirex::ambe2450::Parameters;
using wirex::ysf_vd2_vch::Vch;

struct FrozenVector {
    const char* name;
    Parameters parameters;
    Vch vch;
};

// 向量按固定 MMDVM_CM ModeConv.cpp 的 putAMBE2YSF 映射逐位生成。
// 最后一项来自上游 YSF_SILENCE 填充常量，不是 RF 抓取的通话帧。
constexpr std::array<FrozenVector, 5> frozen_vectors{{
    {"all-zero parameters", {0x000U, 0x000U, 0x0000000U},
     {{0xF3U, 0x19U, 0x37U, 0xDAU, 0x8CU, 0x4CU, 0x3BU, 0xB9U, 0x6BU, 0x7FU, 0x55U, 0x0CU, 0x63U}}},
    {"all-one parameters", {0xFFFU, 0xFFFU, 0x1FFFFFFU},
     {{0x0CU, 0xE6U, 0xC8U, 0x25U, 0x73U, 0xB3U, 0xC4U, 0x46U, 0x94U, 0x80U, 0xAAU, 0xF3U, 0x9DU}}},
    {"alternating parameters", {0xAAAU, 0x555U, 0x1555555U},
     {{0x08U, 0x89U, 0x61U, 0x20U, 0x1CU, 0x5EU, 0x85U, 0x6DU, 0x79U, 0xC1U, 0xA3U, 0x3CU, 0xFFU}}},
    {"field-edge parameters", {0x800U, 0x001U, 0x1000001U},
     {{0x7BU, 0x99U, 0x37U, 0xDAU, 0x8CU, 0x4CU, 0x3BU, 0xB9U, 0x69U, 0x5DU, 0x77U, 0x2CU, 0x73U}}},
    {"pinned YSF silence", {0xF80U, 0x1A9U, 0x13F19C1U},
     {{0x7BU, 0xB2U, 0x8EU, 0x43U, 0x36U, 0xE4U, 0xA2U, 0x39U, 0x78U, 0x49U, 0x33U, 0x68U, 0x33U}}},
}};

void check(bool condition, const char* description)
{
    if (!condition) {
        std::cerr << "FAIL: " << description << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void test_decode_frozen_vectors()
{
    for (const auto& vector : frozen_vectors) {
        const auto actual = wirex::ysf_vd2_vch::decode_vch(vector.vch);
        check(actual.a == vector.parameters.a &&
              actual.b == vector.parameters.b &&
              actual.c == vector.parameters.c,
              vector.name);
    }
}

void test_encode_frozen_vectors()
{
    for (const auto& vector : frozen_vectors) {
        Vch actual{};
        check(wirex::ysf_vd2_vch::encode_vch(vector.parameters, actual),
              "valid parameter fields encode");
        check(actual == vector.vch, vector.name);
    }
}

void test_invalid_fields_preserve_output()
{
    constexpr Vch initial{{
        0xA5U, 0x5AU, 0xC3U, 0x3CU, 0x96U, 0x69U, 0xF0U,
        0x0FU, 0x87U, 0x78U, 0xD2U, 0x2DU, 0xB4U,
    }};
    constexpr std::array<Parameters, 3> invalid{{
        {0x1000U, 0x000U, 0x0000000U},
        {0x000U, 0x1000U, 0x0000000U},
        {0x000U, 0x000U, 0x02000000U},
    }};

    for (const auto& parameters : invalid) {
        auto output = initial;
        check(!wirex::ysf_vd2_vch::encode_vch(parameters, output),
              "out-of-range field is rejected");
        check(output == initial, "rejected parameters leave output unchanged");
    }
}

} // namespace

int main()
{
    test_decode_frozen_vectors();
    test_encode_frozen_vectors();
    test_invalid_fields_preserve_output();
    std::puts("YSF V/D2 VCH frozen-vector and range checks passed.");
    return EXIT_SUCCESS;
}
