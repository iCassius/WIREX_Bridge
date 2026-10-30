# R117 CAT 识别与同步

日期：2026-10-30。此切片拆分 CAT/HRI 串口枚举和匹配规则，并收紧 CAT 查询失败时的能力状态。UI 轮询调度仍由 UI 单独管理；本模块不创建后台守护任务，也不会自动打开串口。

## 空白下拉调查

alpha.12 的 `bridge-ui.ps1` 从 `HARDWARE\DEVICEMAP\SERIALCOMM` 读取当前全部 COM 项，再按 USB VID/PID 补充 HRI 设备。CAT 下拉从 `serial_ports` 遍历全部设备，并将已识别 HRI 项标为不可作 CAT 使用。代码没有只接纳 USB CDC，也没有在 CAT 端口枚举中排除 CP210x。因此，当前源码不能支持“VID/PID 过滤漏掉 CP2105 Enhanced”这一解释。

本次允许范围内进行了只读设备枚举。`Win32_SerialPort` 与 `SERIALCOMM` 均列出 COM5、COM10、COM11；COM10 名称为 Silicon Labs CP2105 Standard，COM11 名称为 CP2105 Enhanced，COM5 的 PNP ID 为 `USB\VID_26AA&PID_0030`。alpha.12 包内 `bridge-ui.ps1` 也含有上述 SERIALCOMM 枚举代码。故本机当前发现到 CP2105 Enhanced；没有打开实体串口，也没有访问 CAT。

进一步复核 `Start-UiDeviceDiscovery` 与完成回调后，确认了串口和音频读取被错误地绑在一起：启动流程先执行 `Start-UiAudioQuery`；若它抛错，catch 会直接返回，串口 discovery runspace 根本不会启动。完成回调也要求 `$serialRecords -and $audio` 同时存在；音频查询失败或超时会使合并失败，并将 `deviceCatalog` 清空。因此，只要音频查询失败，CAT 下拉就会只剩空占位，即使串口本身可以读取。这个耦合缺陷可以从代码确定；现有证据没有证明它就是用户当时看到空白的具体触发事件。

新 catalog 会合并注册表和只读 CIM 结果，以显式来源字段保留两路枚举证据；UI 应将串口 discovery 与音频 discovery 分开启动、接收和报告状态，不能让音频错误清空串口项。UI 接线后可将实际 catalog 计数与分类显示给用户。

## 设备模块接口

文件：`ui/windows/RadioDevices.psm1`。

`Get-RadioDeviceCatalog` 返回 schema 1 对象：

```text
schema_version, discovery_status, serial_ready, source_status,
serial_ports[], hri_ports[], cat_ports[], wave_inputs[], wave_outputs[]
```

每个串口对象包含：

```text
PortName, FriendlyName, InstanceId, HardwareIds, DeviceSource,
IsHri, IsCatCandidate, CatMatchRank, CatMatchReason, Confidence
```

`serial_ports` 收录所有枚举出的 COM 端口。`serial_ready` 只表示串口列表当前是否有项目，不依赖音频设备读取结果。`source_status.registry` 与 `source_status.cim` 分别报告 SERIALCOMM 与 CIM 读取情况。UI 应维护独立的 `serial_ready` 与 `audio_ready`，音频枚举失败或超时不能清空串口列表。

`hri_ports` 按 VID_26AA/PID_0030 或设备说明中的 HRI 标识分类。`cat_ports` 收录所有非 HRI 端口，即使名称和硬件 ID 无法识别；未知端口仍可交由用户手动选。CP2105 Enhanced/CP210x Enhanced 获得更高匹配分；CP2105 Standard 仍可手选。没有任何代码假定 CAT 固定为 COM11。

`Get-RadioDeviceCatalog -SerialPortsInput <对象[]> [-CimPortsInput <对象[]>]` 可接收合成输入供离线测试。显式传入时模块不会调用注册表或 CIM。生产默认枚举只读取 SERIALCOMM 注册表与 `Win32_SerialPort` CIM 类，不修改设备配置，也不打开串口。

`Resolve-RadioDevicePortSelection -Catalog <catalog> [-SavedHriPort <COM>] [-SavedCatPort <COM>] [-ManualCatPort <COM>]` 优先返回当前存在且角色正确的已保存端口；已保存值不存在时，选择唯一的高分硬件匹配。多个相同最高分的 Enhanced 端口不会随机挑选；结果为空并提示手选。若当前保存的 CAT 端口与已识别 HRI 端口冲突，resolver 明确拒绝该值并要求改选，不会静默换成另一端口。

返回对象字段为：

```text
hri_port, cat_port, hri_match_reason, cat_match_reason,
cat_port_source, cat_conflict, needs_manual_hri, needs_manual_cat
```

当 Windows 没有提供 SERIALCOMM 或 CIM 枚举结果时，UI 仍须允许手动输入 `COM1` 到 `COM999`。传入 `-ManualCatPort` 后，resolver 检查格式并拒绝与保存或识别出的 HRI 端口冲突；它会将选择标为 `cat_port_source=manual`，并明确说明当前没有设备身份匹配。UI 需要将此输入保留为 CAT 串口可选项，CAT 模块仍会在打开后验证 `ID0840`。

## CAT 查询失败语义

`Invoke-Ftx1CatOperation -Operation query` 仍以短时 `Open → ID/AI/TX/FA/FB/MD/PC 只读请求 → Close` 读取完整状态。每个成功字段保留各自 `source` 和 `updated_at_utc`，未读字段值为空。UI 可以在一秒左右的低频节奏上调用查询，让设备手动调整后的状态在下一次采样时更新；每次调用最多占用一个 CAT operation slot，忙时应跳过调度周期，不应排队累计。

当总时限耗尽或串口关闭失败时，模块返回 `status=unknown`，保留已读到字段和其实际采样时间，但将 query 与所有 set capability 设为 unavailable。UI 应丢弃旧的写入许可并把缺失的新字段显示为未知；不能把上一轮读数包装成新的成功结果。此模块自身不保存跨次查询缓存。

串口保持每次短开短关，RTS/DTR 均为 false。查询只发 CAT 读取命令；不会发送 TX/PTT、AI 设置或未知 EX 菜单命令。模块仍在每次操作中核对 `ID0840`，设置读回和 TX 防护沿用 R116 约束。

## 离线验证与界限

PowerShell 7 与 Windows PowerShell 5.1 分别通过：

- `tools/test-radio-devices.ps1`：18 项合成断言；覆盖 COM 端口合并去重、HRI VID/PID、CP2105 Enhanced 优先、多个 Enhanced 要求手选、未知项手选、保存值优先、HRI/CAT 冲突拒绝、无枚举时手动 COM 输入和 COM namespace 归一化。
- `tools/test-radio-cat.ps1`：54 项 fake CAT 断言；新增超时和 Close 失败后写入能力全部关闭检查。

Fake 测试没有打开真实串口。设备 catalog 的一次本机读取只使用注册表与 CIM 查询。没有读取或写入用户 CAT 偏好、canonical 配置或密码文件；没有执行 CAT 写操作，也没有启动 HRI、BrandMeister、音频或 RF。

UI 端立即查询、低频轮询、取消/关闭调度和过期状态清理仍需和本模块合同一起完成，并由 UI 调度器保证同一时刻只有一项操作。离线结果不验证串口 CAT 实机通讯、写入行为或射频表现。
