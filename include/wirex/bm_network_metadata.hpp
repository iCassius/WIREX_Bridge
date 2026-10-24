#pragma once

#include "wirex/bm_session.hpp"

namespace wirex::bm {

// 已由虚拟 MMDVM 兼容 WIREX 节点配置验证的 BM RPTC 元数据。
// Gateway ID、呼号、密码和色码由调用方提供，本函数不会覆盖。
inline void apply_network_metadata(Profile& profile)
{
    profile.rx_frequency = 438800000U;
    profile.tx_frequency = 438800000U;
    profile.power = 0U;
    profile.latitude = "0.000000";
    profile.longitude = "00.000000";
    profile.height = 0U;
    profile.location = "DIRECT";
    profile.description = "FTX-1";
    profile.slot_flags = '4';
    profile.url = "www.qrz.com";
    profile.version = "20261024";
    profile.software = "MMDVM_WIREX_Bridge";
    profile.options.clear();
}

} // namespace wirex::bm
