#include "wirex/dmr_vocoder.hpp"

#include "mbe/mbevocoder.h"

#include <mutex>
#include <utility>

namespace {

std::mutex& vocoder_mutex()
{
    static std::mutex mutex;
    return mutex;
}

} // namespace

namespace wirex::dmr_vocoder {

struct Encoder::Impl {
    MBEVocoder codec;
};

Encoder::Encoder() : impl_(std::make_unique<Impl>()) {}
Encoder::~Encoder() = default;
Encoder::Encoder(Encoder&&) noexcept = default;
Encoder& Encoder::operator=(Encoder&&) noexcept = default;

void Encoder::reset()
{
    const std::lock_guard<std::mutex> lock(vocoder_mutex());
    impl_ = std::make_unique<Impl>();
}

Codeword Encoder::encode(const PcmFrame& pcm)
{
    const std::lock_guard<std::mutex> lock(vocoder_mutex());
    if (!impl_) {
        impl_ = std::make_unique<Impl>();
    }

    auto input = pcm;
    Codeword codeword{};
    impl_->codec.encode_2450x1150(input.data(), codeword.data());
    return codeword;
}

struct Decoder::Impl {
    MBEVocoder codec;
};

Decoder::Decoder() : impl_(std::make_unique<Impl>()) {}
Decoder::~Decoder() = default;
Decoder::Decoder(Decoder&&) noexcept = default;
Decoder& Decoder::operator=(Decoder&&) noexcept = default;

void Decoder::reset()
{
    const std::lock_guard<std::mutex> lock(vocoder_mutex());
    impl_ = std::make_unique<Impl>();
}

DecodeResult Decoder::decode(const Codeword& codeword)
{
    const std::lock_guard<std::mutex> lock(vocoder_mutex());
    if (!impl_) {
        impl_ = std::make_unique<Impl>();
    }

    auto input = codeword;
    DecodeResult result{};
    const auto upstream = impl_->codec.decode_2450x1150_with_status(result.pcm.data(), input.data());
    if (upstream.pcm_samples != static_cast<int>(pcm_samples_per_frame) ||
        upstream.corrected_fec_bits < 0) {
        result.status = DecodeStatus::invalid_parameters;
        result.pcm.fill(0);
        return result;
    }
    result.corrected_fec_bits = static_cast<std::uint32_t>(upstream.corrected_fec_bits);

    switch (upstream.marker) {
    case 0:
        result.status = (result.corrected_fec_bits == 0)
            ? DecodeStatus::decoded
            : DecodeStatus::corrected;
        break;
    case 'T':
        result.status = DecodeStatus::tone;
        break;
    case 'R':
        result.status = DecodeStatus::concealed;
        break;
    case 'E':
        result.status = DecodeStatus::erasure;
        result.pcm.fill(0);
        break;
    case 'M':
        result.status = DecodeStatus::muted_repeated_errors;
        result.pcm.fill(0);
        break;
    case 'I':
    default:
        result.status = DecodeStatus::invalid_parameters;
        result.pcm.fill(0);
        break;
    }

    return result;
}

} // namespace wirex::dmr_vocoder
