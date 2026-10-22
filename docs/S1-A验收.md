# S1-A：DIRECT 单记录 envelope 验收

## 实施范围

本切片在 `include/wirex/direct_frame.hpp` 与 `src/direct_frame.cpp` 提供单记录 envelope 的 C++17 纯函数编码与解码，并由 `tests/direct_frame_test.cpp` 覆盖。它不打开串口、不创建 socket、不维护流式缓冲、重试、会话状态、PTT、音频或配置，也不实现 UI。

`type` 保留为原始单字节，payload 按原样保留。函数不检查 X/Y 或其他类型的取值，也不推断 payload 字段含义。

## 记录格式

| 顺序 | 长度 | 字段 | 规则 |
| ---: | ---: | --- | --- |
| 1 | 1 byte | SOH | 固定 `01` |
| 2 | 1 byte | type | 原始字节，不检查值域 |
| 3 | 4 bytes | payload 长度 | 四位 ASCII 十六进制；编码使用大写，解码只接受大写 |
| 4 | 0–65535 bytes | payload | 完全不透明，可包含 `00`、`01`、`03`、`04`、`FF` 等任意字节 |
| 5 | 1 byte | EOT | 固定 `04`，位置由已解析长度确定 |
| 6 | 2 bytes | checksum | 将 SOH 至 EOT（含两端）的字节相加，取低 8 位，编码为两位大写 ASCII 十六进制 |

记录总长度恒为 `payload 长度 + 9`。编码在 payload 超过 `FFFF` 时返回错误，不截断、不返回部分记录。解码逐项检查空指针、最小 9 字节、SOH、长度十六进制、输入长度与声明长度完全相等、声明边界上的 EOT、校验字段十六进制以及校验值。解码只接受大写 ASCII 十六进制；本切片没有根据设备对小写输入的行为扩大接受范围。

## 独立黄金向量

第一条向量是 R31 静态 Direct V0000 序列化路径给出的 9 字节候选，并由 R32 单次 DIRECT 版本查询独立实测确认：

```text
01 56 30 30 30 30 04 31 42
```

该记录的 type 是原始字节 `56`（ASCII `V`），payload 长度为零。校验覆盖 `01 56 30 30 30 30 04`，总和低字节为 `1B`，对应 ASCII `31 42`（`1B`）。

第二条是仅用于测试 envelope 的手算合成向量，不代表设备状态或真实线上记录：

```text
01 58 30 30 30 35 00 01 03 04 FF 04 32 39
```

payload 是 `00 01 03 04 FF`，包含 NUL、记录控制字节和非 ASCII 值，长度为五字节。总和低字节是 `29`。测试分别硬编码两条 expected byte 序列，独立检查 encode 输出与 decode 字段，不以 encode/decode 往返作为唯一 oracle。

## 测试覆盖

- 两条独立黄金向量逐字节核对，并检查原始 type 和 payload 保留。
- 拒绝 null、少于 9 字节、错误 SOH/EOT、大小写或字符非法的长度/校验字段、声明长度不符、错误校验值。
- 用 `1A` 代替 V0000 正确的 `1B`，确认解码会拒绝漏加 SOH 的校验算法。
- 拒绝被截断的 payload 记录和将两条记录拼接后作为一条记录的输入。
- 接受 `FFFF`（65535 字节）payload，检查头部、记录总长、边界 EOT 和独立手算校验；拒绝 65536 字节 payload，不截断。
- 测试使用显式 `check()`，不依赖 `assert`，可在定义 `NDEBUG` 时继续执行。

## 来源与边界

- [R31：实际 USB 帧与 Direct/HRI 工厂分支](../../research/planning/R31_实际USB帧与工厂分支.md)记录了 Direct 序列化器对 SOH、原始类型、四位长度、EOT 与低八位累加校验的静态证据，并说明 V0000 的 9 字节候选。
- [R32：DIRECT 模式下单次版本查询实测](../../research/planning/R32_Direct版本查询独立实测.md)记录了实际发送该 V0000 9 字节记录并收到校验匹配的设备应答；本文只引用脱敏后的请求向量与格式结论，不复制应答 payload 或设备身份。

这些来源支持本切片实现的 envelope 规则，不证明其他 type/payload 的语义、完整 HRI 初始化、音频、PTT、网络或 RF 行为。`direct_frame` 只处理一条已经完整位于内存中的记录，不提供 byte stream 分帧能力。
