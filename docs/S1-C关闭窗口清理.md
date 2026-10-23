# S1-C：控制台关闭时的有界清理

## 范围

本切片只调整 `wirex_probe` 已有的四条本地诊断路径：音频路由、HRI 监听、WAV 播放和输入监测。控制处理器在收到 `CTRL_CLOSE_EVENT` 时只设置取消标记，并等待主线程发出的清理完成事件，最长等待 3000 ms；它不打开、关闭或操作串口、音频资源，也不写状态报告。`CTRL+C` 和 `CTRL+BREAK` 仍通过取消标记让主线程收尾。

主线程按原有流程回收自己持有的资源。HRI 路径在尝试写最终 metadata 后才发出完成事件；其他三条路径在音频资源关闭后发出完成事件。事件句柄保留至进程退出，避免回调等待期间被主线程关闭，最终由操作系统回收。

若等待超时，处理器记录超时并返回 `TRUE`。Windows 对该关闭信号的处理会终止进程，因此应用不能保证主线程之后仍有机会写最终报告或正常返回。若主线程在超时前完成清理并成功写出最终 HRI metadata，报告仍只说明本机句柄清理结果，`radio_state` 仍为 `unknown`；它不证明电台恢复、PTT 状态或 RF 已停止。若系统提前结束进程，最后一份报告可能仍是 `final:false`。关闭窗口后留下的报告不能被解释为电台侧状态。

如果主线程发出清理完成信号或注销处理器失败，程序会在控制台诊断输出前尽力把 HRI final metadata 更新为 `status=failed`，并写明对应失败项。关闭事件可能在这次补写前终止进程；此时仍可能只留下之前的报告，不能保证失败说明一定写入成功。

## Windows 语义

Microsoft 文档说明，控制处理器在系统创建的新线程上执行；`CTRL_CLOSE_EVENT` 处理器返回 `TRUE` 后系统会终止进程，等待时限到期也可能终止进程。文档列出的关闭事件系统时限使用 `SPI_GETHUNGAPPTIMEOUT`，表中为 5000 ms；本切片在此之前使用自己的 3000 ms 等待期限。系统配置或调度可能导致处理过程更早中断。Microsoft 还说明，处理关闭信号期间控制台函数可能无法可靠工作，因此处理器不输出日志。

- [Microsoft：HandlerRoutine 回调函数](https://learn.microsoft.com/en-us/windows/console/handlerroutine)
- [Microsoft：SetConsoleCtrlHandler 函数](https://learn.microsoft.com/en-us/windows/console/setconsolectrlhandler)

## 验收

`tests/console_lifecycle_test.cpp` 覆盖：清理已完成、取消后由主线程释放等待、短期限超时、完成与超时竞态、scope 早退兜底、第二次登记失败不覆盖已有处理器，以及生产 3000 ms 等待期限。测试还启动一个隐藏、独立、无设备子进程，向它自己的控制台窗口投递 `WM_CLOSE`，观察 `CTRL_CLOSE_EVENT` 是否取消主线程并允许它记录清理完成。若 Windows 环境不接受该窗口关闭请求，测试会报告跳过，不能据此声称实际关闭事件已经验证。

本机和主会话分别从源码使用 VS2019 x64 C++17、`/W4 /MT` 编译；生命周期测试和完整 `wirex_probe` 均成功，构建没有警告。生命周期测试通过正常完成、取消释放、期限超时、完成/超时竞态、scope 早退、重复登记失败和生产 3000 ms 上限检查；隐藏子进程实际收到 `CTRL_CLOSE_EVENT` 并记录主线程清理完成。测试没有打开串口或音频设备，也没有验证 HRI、PTT、射频或电台状态；它只验证 Windows 进程内的取消与收尾协作。
