# S3-A：DMRD 55-byte codec 验收

## 实施范围

本地 C++17 纯函数 codec：`include/wirex/dmrd.hpp` 与 `src/dmrd.cpp`。单元测试位于 `tests/dmrd_test.cpp`。项目不创建 socket、不执行登录/认证、不维护状态机，也不接触音频、串口、PTT 或 RF。

## 字段布局

固定源代码为 R3 pinned `nostar/DroidStar` commit `becf1dede57c4a70a865e9cb4cac9247e505599a` 的 `dmr.cpp`，以及 `juribeparada/MMDVM_CM` commit `7328c9e9532d29cf4d9d7d24541d57f825207be4` 的 `USRP2DMR/DMRNetwork.cpp`。后者的 `CDMRNetwork::read/write` 明确使用下列字节范围；前者在 `dmr.cpp` 的 DMRD 收包路径检查 55-byte 长度、magic 和 payload offset 20。

| Offset | 长度 | 本切片表示 | 处理方式 |
| ---: | ---: | --- | --- |
| 0 | 4 | magic | 固定 `DMRD`；解析时严格检查，编码时固定写入 |
| 4 | 1 | sequence | 原始 byte |
| 5 | 3 | source ID | big-endian 24-bit |
| 8 | 3 | destination ID | big-endian 24-bit |
| 11 | 4 | gateway ID | big-endian 32-bit |
| 15 | 1 | flags | 原始 byte，不解释位含义 |
| 16 | 4 | stream ID | 原始 4-byte array，不猜测主机序 |
| 20 | 33 | payload | 原始 33-byte array，不解释编码或内容 |
| 53 | 1 | BER | 原始 byte |
| 54 | 1 | RSSI | 原始 byte |

`CDMRNetwork::write` 在 offset 11 拷贝 4-byte gateway ID，在 offset 16 拷贝 stream ID 数组，在 offset 20 写入 33-byte data，并将 BER/RSSI 放在 53/54。`CDMRNetwork::read` 从 offset 4–10 读取序号与 ID，按 20-byte 偏移取 payload。这里仅采用固定字段布局，没有引入 `CDMRNetwork` 的在线状态或包处理逻辑。

## 验收覆盖

测试使用固定、手写的向量（非由 encoder 生成）：

```text
44 4d 52 44 a5 12 34 56 ab cd ef 89 ab cd ef e7
01 23 fe 80
00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f
10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f 20
5a c3
```

该向量覆盖 sequence、两种 24-bit ID、gateway 32-bit、未知 flags、非对称 stream ID bytes、payload、BER 与 RSSI。测试同时覆盖：

- 解码 54 与 56 bytes 均因长度错误拒绝，55-byte 错 magic 拒绝，空指针拒绝。
- 24-bit 最大 source/destination ID 可编码为 `ff ff ff` 并解回原值。
- source 与 destination 各自超过 24-bit 时分别返回错误，不做截断。
- 任意 flags、stream ID 字节和 payload byte 透明经过 encode/decode。
- 编码黄金记录必须逐字节等于独立硬编码向量。

测试中的 `check()` 显式报告失败并退出非零；它不使用可能被 `NDEBUG` 关闭的 C/C++ `assert`。

## 本机验证记录

使用 Visual Studio 2019 x64 工具链（MSVC 19.29.30159）编译 `src/dmrd.cpp` 和 `tests/dmrd_test.cpp`，编译选项为 `/std:c++17 /EHsc /W4 /permissive-`。测试程序输出：`All DMRD codec checks passed.`。该次本机生成的 `build/dmrd_test.exe` SHA-256 为 `3C2FF06C2A8B58EC6F2F106359E7E82E6D3E07D455988612C53E413704DB9D10`；`build/` 已由 `.gitignore` 排除，不纳入源码提交。

## 能力边界

编译和测试只验证本地数据结构与字节布局，不证明任何远端协议会话、DMR 内容有效性、LC/FEC 校验、语音 codec、BrandMeister 互通或无线发射能力。payload 和 flags 保持不透明，stream ID 维持原始字节顺序。
