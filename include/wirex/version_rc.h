#ifndef WIREX_VERSION_RC_H
#define WIREX_VERSION_RC_H

// 版本与作者信息的单一来源。此文件同时被 C++（version.hpp）与 rc.exe 读取，
// 因此只能使用普通宏，不能出现任何 C++ 语法。发版时只改这里。
#define WIREX_VERSION_MAJOR 0
#define WIREX_VERSION_MINOR 2
#define WIREX_VERSION_PATCH 3
#define WIREX_VERSION_STR "0.2.3"   // 不含 "v" 前缀
#define WIREX_AUTHOR "BI7KGD"

#endif // WIREX_VERSION_RC_H
