# R103：HRI T 记录到 WriteFile 路径摘要

本摘要记录固定 WIRES-X 2.010 样本的静态调用与数据流。分析没有运行官方程序或厂商 DLL，也没有访问串口、音频、网络或电台；结论仅覆盖静态代码路径。

| 样本 | SHA-256 |
|---|---|
| `WIRES_X.EXE` | `8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671` |
| `HRI_UART.dll` | `56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed` |
| `RigDataIf.dll` | `94d1217feb047288329e79e0d5de2167c79450f1945119b2ed6c6376b02a7410` |

HRI 函数 `FUN_10014b50` 将 T 正文交给 `FUN_1000b130(*(int *)(this+0x2b4), t_body)`。后者按 `strlen` 计算正文长度，通过 node `+0x14` 的间接 factory 创建 T 类型记录，并请求 `正文长度 + 9` 的容量，再复制正文、调用 finalize slot，最后由 `FUN_1000a140` 入队。多出的 9 字节如何分配，以及 factory/finalize 的完整实现，仍未恢复。

HRI 队列泵 `FUN_1000a240` 读取队首记录。在 T 分支，它从 `record + queue[4]` 检查类型并扫描五个 `'*'`；后续 ASCII HEX 解析用于诊断。随后它调用 `SendMessageA(hwnd, 0x618, record_ptr, record_length)`，参数沿用队列项指针和长度。`queue[4]` 的运行时值未知。

EXE 的窗口消息链为 `0x00497b50 → 0x0040d260 → 0x0040f7e0 → WriteFile(handle, buffer_ptr, length, &bytesWritten, NULL)`。静态路径将缓冲区指针和长度传给 `WriteFile`。尚未恢复该 handle 的创建与 COM 绑定，因此此链不能证明串口实际写入、电台接收或 LCD 显示。它也没有恢复数字 RF serializer 或 codec。

新增 R103 函数 Evidence ID：`ev_197da0b900013b8b5a094d9c97889641cbeee1c540e7f5c637e4983435051c4d`。配套 `WM 0x618 → WriteFile` 调用链见既有静态研究记录。原始 REA bundle 保存在本机研究目录，不进入仓库或发布包。
