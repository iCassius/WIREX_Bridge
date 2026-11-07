#pragma once

#include "wirex/version_rc.h"

// 程序版本与作者信息（单一来源见 version_rc.h）。发版时只改 version_rc.h；
// wirex package-gui 会校验 --version 与此一致。
namespace wirex {

inline constexpr const char* app_version = WIREX_VERSION_STR;   // 不含 "v" 前缀
inline constexpr const char* app_author = WIREX_AUTHOR;
inline constexpr const char* app_repository = "iCassius/WIREX_Bridge";
inline constexpr const char* app_releases_url = "https://github.com/iCassius/WIREX_Bridge/releases";

} // namespace wirex
