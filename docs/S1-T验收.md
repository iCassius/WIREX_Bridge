# S1-T：HRI T 空载候选正文

## 范围

本切片以 [R63 构造与应答映射](../../research/planning/R63_T候选空载构造与应答映射.md) 和 [R63 合成 fixture](../../research/rea/v2.010/r63_empty_t_fixture.json) 为依据，新增纯 C++17 函数 `wirex::hri_t_payload::build_empty_header_empty_ambe_candidate_body`。函数接收原始 `PttSw`、`field50`、`flags248c` 字段，返回固定 90 字节的 ASCII T 候选正文，不含 NUL。它只组装离线候选数据，没有发送入口。

selector 规则为：`PttSw != 1` 时写 `'0'`；`PttSw == 1 && field50 == 1` 时写 `'3'`；其他情况在 `flags248c & 4` 非零时写 `'1'`，否则写 `'2'`。

正文偏移 1–6 为 `000000`；68 字节默认 header 位于偏移 7–74，除偏移 7=`'2'`、9=`'1'`、10=`'1'`、11=`'4'` 外其余均为 ASCII `'0'`；偏移 75–80 为 `00001F`；81–85 为 `*****`；86–89 为 `3033`。

## 离线验证

`tests/hri_t_payload_test.cpp` 以 R63 fixture 的完整 90 字符 literal 独立校验正文，并覆盖四种 selector 结果和 flags 位掩码。测试再调用现有 `direct_frame::encode`，核对 `SOH + T005A + 正文 + EOT` 共 99 字节，以及 selector `'0'`、`'1'`、`'2'`、`'3'` 对应的 ASCII checksum `19`、`1A`、`1B`、`1C`。

验证使用 VS 2019 Build Tools 16.11.52 x64：调用 `vcvarsall.bat x64` 后执行：

```bat
if not exist build\review-s1t mkdir build\review-s1t
cl /nologo /std:c++17 /EHsc /W4 /permissive- /utf-8 /MT /I include /Fo:build\review-s1t\ src\hri_t_payload.cpp src\direct_frame.cpp tests\hri_t_payload_test.cpp /Fe:build\review-s1t\hri_t_payload_test.exe
build\review-s1t\hri_t_payload_test.exe
```

编译无警告；测试程序输出 `All HRI T candidate payload checks passed.` 并以退出码 0 结束。本机未安装 CMake，因此没有运行 CMake 配置或 CTest。

基线提交：`e1c1a9bd12594fcb94a62a530b0357d906fe33f9`。结果提交哈希会记入[根进度文档](../../docs/12_项目进度大纲.md)。

## 证据边界

R63 fixture 是静态规则的合成夹具，且空队列由 synthetic override 指定。此候选正文不证明运行时队列为空，也不证明 DLL/UART 发送、扬声器播放、电台发送、PTT 或 RF 效果。本文没有把 selector 解释成产品层面的启动或停止含义。
