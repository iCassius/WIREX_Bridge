#requires -Version 5.1
Set-StrictMode -Version Latest

$script:WirexUiEnglishText = [ordered]@{
    '未连接'='Not connected'; '已连接'='Connected'; '连接中'='Connecting'; '已断开'='Disconnected'; '已停止'='Stopped';
    '恢复中'='Recovering'; '准备中'='Preparing'; '未启动'='Not started'; '未知'='Unknown';
    '丢包'='Loss'; '停止并退出'='Stop and exit'; '来话历史'='Call history'; '设为PTT呼叫目标'='Set TX target';
    '连接配置'='Connection setup'; '刷新设备'='Refresh devices'; 'Wires-X 串口'='Wires-X port'; 'CAT 串口'='CAT port'; '波特率'='Baud rate';
    '连接串口'='Connect radio'; '正在断开串口'='Disconnecting'; '取消连接'='Cancel connect'; '断开串口'='Disconnect radio';
    'MAIN 模式'='MAIN mode'; '频率 MHz'='Frequency MHz'; '功率 W'='Power W'; '应用'='Apply'; '设为PTT目标'='Set TX target';
    '呼号'='Callsign'; 'DMR ID'='DMR ID'; '设备编号'='Device no.'; 'BM 服务器'='BM server'; 'UDP 端口'='UDP port'; '主机名 / IPv4'='Host / IPv4';
    'BM 密码'='BM password'; 'BM 密码  '='BM password  '; '设置'='Set up'; '连接BM'='Connect BM'; '保存配置'='Save settings'; '日常控制'='Daily controls';
    '增加动态组 频道ID'='Add group or private ID'; '类型'='Type'; '请选择'='Select'; '单呼'='Private'; '组呼'='Group';
    '加入监听'='Add to listening'; '增加BM静态组'='Add BM static group'; '刷新'='Refresh'; '移除'='Remove'; '需启用BM API key'='BM API key required';
    '添加为静态组'='Add as static group'; '音频设备'='Audio devices'; '输入'='Input'; '输出'='Output'; '音量'='Audio'; '播放增益'='Playback gain'; '发送增益'='Transmit gain';
    '自定义'='Custom'; '取消监听'='Remove'; '临时屏蔽'='Mute'; '恢复收听'='Unmute'; '呼叫目标'='TX target'; '设为呼叫'='Set TX';
    '静态组'='Static'; '动态组'='Dynamic'; '取消排队'='Cancel'; '请求处理中'='Joining…'; '再次激活'='Rejoin'; '激活组'='Join';
    '仅当该ID和类型已经在频道列表中时，才能设为PTT目标。'='The ID and type must already be in the channel list to set it as the TX target.';
    '已选为下次 PTT 呼叫目标'='Selected as the next TX target'; '选择此频道作为下次 PTT 目标'='Select this channel as the next TX target';
    '频道说明'='Channel notes'; '新加入的频道会进入监听列表。呼叫目标可在频道卡片上单独选择。'='New channels are added to the listening list. Set the TX target separately on each channel card.';
    '关闭'='Close'; 'TG'='TG'; '设备'='Device'; 'RTT'='RTT'; 'BM API 操作失败；请检查 API Key 与网络后刷新。'='BM API request failed. Check the API key and network, then refresh.';
    'BM API 操作超时；请刷新列表确认服务器状态。'='BM API request timed out. Refresh the list to check server state.';
    'BM 已接受静态组更改，但回查未完成；请刷新确认。'='BM accepted the static group change, but verification did not finish. Refresh to confirm.';
    'BM 已接受静态组更改，但读取结果与请求不符；请检查列表。'='BM accepted the static group change, but the returned list differs. Check the list.';
    'BM 已接受静态组更改，读取列表已确认。'='BM accepted the static group change and the refreshed list confirms it.';
    'BM 返回的设备 ID 与本次请求不一致；列表已清除。'='BM returned a different device ID. The list was cleared.';
    'BM 静态组后台操作未能启动。'='Could not start the BM static group operation.'; 'BM 静态组操作正在进行。'='BM static group operation in progress.';
    'BM 静态组模块不可用。'='BM static group module is unavailable.'; 'BM 静态组读取已取消。'='BM static group read was cancelled.';
    '设备或 API Key 已变更；未显示旧设备的 BM 静态组。'='The device or API key changed. Static groups from the previous device are hidden.';
    '设备或 API Key 已变更；请刷新 BM 静态组。'='The device or API key changed. Refresh BM static groups.';
    '设备状态不可用；添加已禁用。'='Device state is unavailable. Adding is disabled.'; '该静态组已存在。'='This static group already exists.';
    '请先保存有效的 BM 设备 ID。'='Save a valid BM device ID first.'; '请先读取当前设备的 BM 静态组。'='Read BM static groups for this device first.';
    '请先选择当前设备的一条 BM 静态组。'='Select a BM static group for this device first.';
    '请输入 1 至 16777215 的静态组 ID。'='Enter a static group ID from 1 to 16777215.'; '请输入 BM API Key。'='Enter the BM API key.';
    '静态组写入结果未确认；请刷新列表后再操作。'='The static group write is unconfirmed. Refresh the list before continuing.';
    'CAT 状态读取失败或端口已变化；已取消设置，没有写入。'='CAT status read failed or the port changed. The setting was cancelled without writing.';
    'CAT 设置没有执行；无法先完成当前端口读取。'='CAT setting was not applied because the current port could not be read first.';
    'HRI 已停止；没有执行 MAIN 设置。'='HRI stopped. The MAIN setting was not applied.';
    '已冻结模式、频率和功率目标；当前读取完成并确认身份、端口和TX状态后继续。'='Mode, frequency, and power targets are fixed. Continue after the current read confirms radio, port, and TX state.';
    '当前串口操作结束后执行用户请求的读取。'='The requested read will run after the current serial operation.';
    '操作已取消；结果未知。'='Operation cancelled; result is unknown.';
    '暂时无法读取电台状态；CAT会话保留并等待下一次轮询。'='Radio state is temporarily unavailable. The CAT session remains open for the next poll.';
    '暂时无法读取电台状态；端口恢复后会重新读取。'='Radio state is temporarily unavailable. Reading will resume when the port is back.';
    '用户请求的读取没有完成；请检查 CAT 端口后重试。'='The requested read did not finish. Check the CAT port and try again.';
    '设置未获确认；请重新读取电台状态。'='The setting was not confirmed. Read the radio state again.';
    'CAT串口从设备列表消失；正在等待重新枚举。'='The CAT port disappeared from the device list. Waiting for it to reappear.';
    'CAT状态读取失败；等待下一次读取。'='CAT status read failed. Waiting for the next read.'; 'CAT状态读取已恢复。'='CAT status reading has recovered.';
    '本机控制通道尚未确认；未发送激活请求。'='The local control channel is not confirmed. No activation request was sent.';
    '本机正在停止或切换运行会话；未发送激活请求。'='The local session is stopping or changing. No activation request was sent.';
    '正在断开 BM；未发送激活请求。'='BM is disconnecting. No activation request was sent.';
    'BM 密码未填写，未发起连接。'='BM password is empty. No connection was started.'; 'BM 正在连接'='Connecting to BM';
    'BM 正在断开并清理网络媒体'='Disconnecting from BM and clearing network media'; 'BM 正在重试连接'='Retrying BM connection';
    'BM 正在恢复连接'='Restoring BM connection'; 'BM 已收到登录确认'='BM login confirmed'; 'BM 已断开；正在停止 HRI 核心，CAT 串口已收尾。'='BM disconnected. Stopping the HRI core; the CAT port has closed.';
    'BM 网络会话已停止并关闭 UDP'='BM network session stopped and UDP closed'; 'BM 主站名称解析中'='Resolving BM server name';
    'BM 连接请求将在 HRI 就绪后发送。'='The BM connection request will be sent when HRI is ready.';
    'BM 连接请求已排队，等待 HRI 就绪。'='BM connection request queued until HRI is ready.';
    'BM 连接状态异常，请重新连接串口。'='BM connection state is inconsistent. Reconnect the serial port.';
    'BM 连接状态尚未更新；请检查当前连接状态后重试。'='BM connection state has not updated. Check the current state and try again.';
    'HRI 与电台音频接口已就绪'='HRI and radio audio are ready'; 'HRI 串口已关闭'='HRI serial port closed';
    'HRI 串口已打开，等待设备就绪'='HRI serial port opened; waiting for the device'; 'HRI 就绪'='HRI ready'; 'HRI 未连接'='HRI disconnected';
    'HRI 连接中'='Connecting to HRI'; 'HRI 保持断开；先读取电台状态，再应用 MAIN VFO 设置。'='HRI remains disconnected. Read radio state before applying MAIN VFO settings.';
    'HRI 已停止；MAIN VFO 设置未完成，可在设置中核对 CAT-1 状态。'='HRI stopped before MAIN VFO settings finished. Check CAT status in settings.';
    'HRI 核心没有退出；CAT 已断开，串口核心仍保持运行。'='HRI core did not exit. CAT disconnected; the serial core is still running.';
    'CAT 功率设置保存失败。'='Could not save the CAT power setting.'; '无法打开 QRZ 呼号资料页。'='Could not open the QRZ callsign page.';
    '无法打开电台资料页面。'='Could not open the radio profile page.'; '无法打开设置页面。'='Could not open the settings page.';
    '统一配置无法读取；请检查 config.json。'='Could not read the portable settings. Check config.json.';
    '设备刷新失败，请重试。'='Device refresh failed. Try again.'; '设置已保存。'='Settings saved.';
    '请先填写并保存 BM 密码，再连接 BM。'='Enter and save the BM password before connecting.';
    '正在应用频道设置；收到核心确认前保留当前列表。'='Applying channel settings. The current list stays until the core confirms.';
    '核心没有接收频道设置；当前频道列表保持不变。'='The core did not accept the channel settings. The channel list is unchanged.';
    '核心尚未准备好接收频道设置。'='The core is not ready to receive channel settings.';
    '当前没有连接核心。'='The core is not connected.'; '请等待当前发射与清理结束后再切换 PTT 目标。'='Wait for transmit and cleanup to finish before changing the TX target.';
    '正在安全停止'='Stopping safely'; '正在准备连接'='Preparing connection'; '正在准备连接。'='Preparing connection.';
    '正在停止当前连接'='Stopping the current connection'; '正在停止连接；不会自动重连。'='Stopping the connection. It will not reconnect automatically.';
    '正在切换连接目标。'='Changing connection target.'; '已停止连接并移除最后一个频道。'='Connection stopped and the last channel was removed.';
    '本机控制已确认'='Local control confirmed'; '控制协议：等待 v2 control_ready'='Control protocol: waiting for v2 control_ready';
    '核心进程已启动'='Core process started'; '核心已启动，正在确认本机控制通道'='Core started. Confirming the local control channel';
    '核心已确认频道状态。'='The core confirmed channel state.'; '核心设置状态校验失败'='Core settings state validation failed';
    '核心状态查询失败；请检查连接状态。'='Could not query core state. Check the connection.';
    '核心状态过期，取消 CAT 功率操作失败'='Core state expired. Could not cancel the CAT power operation.';
    '核心空闲状态过期，取消 CAT 功率操作失败'='Core idle state expired. Could not cancel the CAT power operation.';
    '动态组激活失败'='Dynamic group activation failed'; '动态组激活未完成'='Dynamic group activation incomplete';
    '动态组激活等待超时；保留原 request_id，没有自动重发'='Dynamic group activation timed out. The request ID is retained; it was not retried.';
    '动态组激活部分发送：header 已发送，EOT 发送失败；核心没有重试'='Dynamic group activation partially sent: header sent, EOT failed. The core did not retry.';
    '动态组激活失败：'='Dynamic group activation failed: ';
    'CAT-1 操作清理失败'='CAT-1 cleanup failed'; 'CAT-1 操作超出期限，已请求关闭串口'='CAT-1 operation timed out; serial port close requested';
    'CAT-1 取消后 3 秒仍未确认串口清理；安全退出界面'='Serial cleanup was not confirmed 3 seconds after CAT-1 cancellation. Closing safely.';
    '设置未完成；请重新读取电台状态。'='The setting did not finish. Read the radio state again.';
    '来话 {0} · 私呼 · 来源 N0T'='Call {0} · Private · from N0T';
    '断开BM'='Disconnect BM'; '正在连接BM'='Connecting…'; '正在断开BM'='Disconnecting…';
    '正在解析 BM 主站'='Resolving BM server'; '正在断开'='Disconnecting'; '连接失败'='Connection failed'; '正在连接'='Connecting'; '正在重试'='Retrying';
    '正在查找 BM 主站。'='Looking up the BM server.'; '正在断开 BM 并清理语音。'='Disconnecting from BM and clearing voice media.';
    '正在断开 BM。'='Disconnecting from BM.'; 'BM 已连接。'='BM connected.'; '正在连接 BM。'='Connecting to BM.';
    'BM 连接失败，请检查连接设置。'='BM connection failed. Check the connection settings.';
    'BM 连接失败：请先填写 BM 密码并保存配置。'='BM connection failed. Enter and save the BM password first.';
    'BM 主站地址解析失败，请检查地址或网络。'='Could not resolve the BM server. Check the address or network.';
    'BM 主站解析超时，请检查地址或网络。'='BM server lookup timed out. Check the address or network.';
    'BM 主站解析取消超时。'='BM server lookup cancellation timed out.';
    'BM 连接参数无效；请检查主机、UDP 端口、呼号和 ID。'='BM connection settings are invalid. Check host, UDP port, callsign, and ID.';
    'BM UDP 传输未能打开；请检查端口和本机网络。'='Could not open BM UDP transport. Check the port and local network.';
    'BM 断开超时，正在清理语音。'='BM disconnect timed out. Clearing voice media.';
    'BM 状态已更新，请重试。'='BM state changed. Try again.'; 'BM 正在切换或收发，请稍后重试。'='BM is switching or handling traffic. Try again shortly.';
    'BM 密码未填写；请填写并保存后重新连接。'='BM password is empty. Enter and save it, then reconnect.';
    'BM 主站地址解析失败；请检查服务器地址和网络后重试。'='Could not resolve the BM server. Check the server address and network, then try again.';
    'BM 连接参数无效；请检查呼号、ID、主站和端口。'='BM connection settings are invalid. Check callsign, ID, server, and port.';
    'BM UDP 连接未能打开；请检查端口和本机网络。'='Could not open the BM UDP connection. Check the port and local network.';
    'BM 已断开。'='BM disconnected.'; '正在读取 BM 静态组。'='Reading BM static groups…';
    '正在向 BM 添加静态组。'='Adding a BM static group…'; '正在向 BM 移除静态组。'='Removing a BM static group…';
    '正在确认上一项 BM 连接请求。'='Confirming the previous BM connection request.'; '正在读取 BM 当前连接状态。'='Reading the current BM connection state.';
    '正在断开 BM；等待核心状态确认。'='Disconnecting from BM; waiting for core confirmation.';
    '正在连接 BM；等待核心状态确认。'='Connecting to BM; waiting for core confirmation.';
    '当前连接使用运行会话中显示的目标。'='The current connection uses the target shown in the active session.';
    '当前运行设置已刷新'='Current runtime settings refreshed'; '当前运行设置已刷新，草稿已保留'='Current runtime settings refreshed; the draft was kept';
    '当前运行设置无法刷新；路由修改保持锁定，请重新连接。'='Could not refresh runtime settings. Routing changes remain locked; reconnect.';
    '当前运行设置无法刷新；路由修改已锁定，请重新连接后再试。'='Could not refresh runtime settings. Routing changes are locked; reconnect and try again.';
    '核心控制能力与确认结果不一致'='Core control capabilities do not match the confirmation';
    '核心没有接收 BM 连接请求；当前连接状态保持不变。'='The core did not accept the BM connection request. Connection state is unchanged.';
    'BM 连接切换遭核心拒绝；当前实际状态已刷新。'='The core rejected the BM connection change. The current state was refreshed.';
    'BM 连接确认与请求版本不一致；正在读取核心实际状态。'='The BM confirmation does not match the request version. Reading the actual core state.';
    'BM 连接离开 ready；本机会话的组呼请求标记已清除'='BM left the ready state. The local group call request marker was cleared.';
    'BM 已停止'='BM stopped'; 'BM 已连接'='BM connected';
    'BM 静态组请求收尾失败。'='Could not finish the BM static group request.';
    '自动：唯一 HRI 设备'='Auto: unique HRI device';
    '自动：唯一 USB Audio 端点'='Auto: unique USB Audio endpoint'; '未确认 HRI'='HRI unverified'; '设备信息未确认'='Device unverified';
    '460997 中国鹦鹉'='460997 China Parrot'; '46001 组呼'='46001 Group'; '91 组呼'='91 Group';
    '00–99。旧 Gateway 无法拆分时留空；未编辑时保留原值。'='00–99. Leave blank if an older gateway cannot be split; the original value is kept unless edited.';
    '当前通话结束前暂存的激活请求；点击可取消，最多等待 60 秒。'='Activation request queued until the current call ends. Click to cancel; wait limit is 60 seconds.';
    '一项激活请求正在等待本机结果；结果返回或等待超时后可再次操作。'='An activation request is waiting for a local result. Try again after a result or timeout.';
    '另一频道已有激活请求排队；请取消或等待该请求结束。'='Another channel has an activation request queued. Cancel it or wait for it to finish.';
    'RenderOnly 离线界面检查提示'='RenderOnly offline UI check message';
    '来话结束清理失败；电台状态待核实'='Incoming call cleanup failed; radio state needs verification';
    '界面语言保存失败：'='Could not save interface language: ';
    'BM API Key 保存失败。'='Could not save the BM API key.';
    '重试中'='Retrying';
    '功率已在CAT读取中确认，保存本机偏好失败'='Power was confirmed by CAT readback, but the local preference could not be saved';
    '已一致，跳过写入'='Already matches; write skipped'; '已读回目标值'='Target value confirmed by readback';
    '未获确认'='Not confirmed'; '未执行'='Not run'; '状态未知'='State unknown';
    'CAT 设置未全部完成；已读回确认的字段没有自动回滚。'='CAT settings are incomplete. Readback-confirmed fields were not rolled back.';
    'CAT 设置已取消；已读回确认的字段没有自动回滚。'='CAT settings were cancelled. Readback-confirmed fields were not rolled back.';
    'CAT 状态已读取；模式、频率、功率均与目标一致，没有发送设置帧。'='CAT state was read. Mode, frequency, and power already match; no setting frames were sent.';
    'CAT 模式、频率、功率已逐项读取；变化字段已读回目标值。'='CAT mode, frequency, and power were read individually; changed fields were confirmed by readback.';
    'CAT 设置已取消，没有发送写入：'='CAT settings were cancelled. No write was sent: ';
    '当前条件不允许发送该设置：'='Current conditions do not allow this setting to be sent: ';
    '应用中：'='Applying: '; '；每项均单独读取并核对回读。'='; each setting is read and checked individually.';
    '后续：'='Next: '; '模式'='Mode'; '频率'='Frequency'; '功率'='Power';
    'MAIN VFO 频率必须使用 MHz 十进制数，最多 6 位小数。'='MAIN VFO frequency must be a decimal MHz value with no more than 6 decimal places.';
    'MAIN VFO 频率数值无效。'='The MAIN VFO frequency is invalid.';
    'MAIN VFO 频率必须是整数 Hz，范围为 0.030000 到 470 MHz。'='MAIN VFO frequency must be a whole number of Hz from 0.030000 to 470 MHz.';
    '请先选择功率，再明确应用该草稿值。'='Choose a power level before applying this draft.';
    '目标功率超出电台当前范围；请先明确选择合法值。'='The target power is outside the radio range. Choose a valid value first.';
    '请选择明确的 MAIN 调制模式。'='Choose a specific MAIN modulation mode.';
    '请选择一个功率值后再应用。'='Choose a power value before applying.';
    '目标功率范围已变化；请先在当前范围内重新选择功率。'='The target power range changed. Choose a power value in the current range.';
    '已有一项 CAT 用户动作正在等待执行。'='A CAT user action is already waiting to run.';
    '另一项 CAT 写入正在执行；请等待该操作结束。'='Another CAT write is in progress. Wait for it to finish.';
    'CAT 设置字段无效。'='The CAT setting field is invalid.';
    'CAT 端口或会话已变化；已撤销未执行的字段。'='The CAT port or session changed. Unexecuted fields were cancelled.';
    'CAT-1 与当前 HRI 串口不能共用；已停止后续设置。'='CAT-1 and the active HRI port cannot be shared. Further settings were stopped.';
    '核心正在准备、停止或收尾；已停止后续设置。'='The core is preparing, stopping, or cleaning up. Further settings were stopped.';
    '核心状态未确认 PTT 已释放且队列为空；已停止后续设置。'='The core has not confirmed PTT release and an empty queue. Further settings were stopped.';
    '新读取的功率路径不接受已冻结的目标功率。'='The newly read power path does not accept the fixed target power.';
    '核心状态未确认电台空闲；设置已取消。'='The core has not confirmed the radio is idle. The setting was cancelled.';
    '只有组呼频道可激活动态组。'='Dynamic groups can only be activated from group channels.';
    '该频道已从本机监听列表移除或屏蔽；未发送激活请求。'='This channel was removed from the local listening list or muted. No activation request was sent.';
    '该组已由当前 BM 设备静态组列表确认；无需发送激活请求。'='This group is confirmed in the current BM device static group list. No activation request is needed.';
    '本机媒体状态已超过 3 秒；未发送激活请求。'='Local media status is over 3 seconds old. No activation request was sent.';
    'BM 尚未确认 ready；未发送激活请求。'='BM has not confirmed ready. No activation request was sent.';
    '本机媒体仍忙；本次激活没有发送。'='Local media is still busy. This activation was not sent.';
    '频道设置仍在处理；未发送激活请求。'='Channel settings are still being processed. No activation request was sent.';
    '本机仍在处理另一项激活请求；未发送本次请求。'='Another activation request is still being processed locally. This request was not sent.';
    '本机媒体状态无法确认安全排队；未发送激活请求。'='Local media state cannot confirm that queueing is safe. No activation request was sent.';
    '该频道已从本机监听列表移除或屏蔽；排队取消，没有发送激活请求。'='This channel was removed from the local listening list or muted. The queued request was cancelled; nothing was sent.';
    '该组已由当前 BM 设备静态组列表确认；排队取消，无需发送激活请求。'='This group is confirmed in the current BM device static group list. The queued request was cancelled; nothing needed to be sent.';
    '本机正在停止或切换运行会话；排队取消，没有发送激活请求。'='The local session is stopping or changing. The queued request was cancelled; nothing was sent.';
    '正在断开 BM；排队取消，没有发送激活请求。'='BM is disconnecting. The queued request was cancelled; nothing was sent.';
    'Native 运行会话已变化；排队取消，没有发送激活请求。'='The Native session changed. The queued request was cancelled; nothing was sent.';
    'Native 控制能力已不可用；排队取消，没有发送激活请求。'='Native control is unavailable. The queued request was cancelled; nothing was sent.';
    '本机状态已切换到另一运行会话；排队取消，没有发送激活请求。'='Local state switched to another session. The queued request was cancelled; nothing was sent.';
    'BM 连接离开 ready；排队取消，没有发送激活请求。'='BM left the ready state. The queued request was cancelled; nothing was sent.';
    '频道设置开始更新；排队取消，没有发送激活请求。'='Channel settings started updating. The queued request was cancelled; nothing was sent.';
    '本机媒体状态无法确认空闲；排队取消，没有发送激活请求。'='Local media state cannot confirm idle. The queued request was cancelled; nothing was sent.';
    '已取消 TG {0} TS{1} 的排队；没有发送激活请求。'='Cancelled the queued request for TG {0} TS{1}; no activation request was sent.';
    '另一频道已有激活请求排队；请先取消或等待该请求结束。'='Another channel already has an activation request queued. Cancel it or wait for it to finish.';
    '上一项激活请求仍在等待本机结果。'='The previous activation request is still waiting for a local result.';
    '动态组激活请求没有送达本机 Native。'='The dynamic group activation request did not reach local Native.';
    'TG {0} TS{1} 激活请求已提交。'='TG {0} TS{1} activation request submitted.';
    '向本机 Native 请求发送一次动态组 Quick Call；本机只报告发送结果，不回读 BM 当前动态组。'='Send one dynamic group Quick Call to local Native. The local result reports transmission only; it does not read back the current BM dynamic group.';
    '当前无法单独连接 BM，请先断开串口后重连。'='BM cannot connect separately in the current state. Disconnect the serial port, then reconnect.';
    '正在断开 BM；HRI 与 CAT 保持运行。'='Disconnecting from BM; HRI and CAT will remain running.';
    '串口断开等待超时；HRI 和 CAT 仍保持连接'='Serial disconnect timed out; HRI and CAT remain connected.';
    'BM 状态尚未更新；串口保持连接等待关闭确认。'='BM state has not updated; the serial port remains connected while waiting for shutdown confirmation.';
    'Wires-X 启动因 CAT/HRI 串口冲突取消'='Wires-X startup cancelled because the CAT and HRI ports conflict.';
    'CAT 设置未完成，请稍后再启动 Wires-X。'='CAT settings are incomplete. Start Wires-X again after they finish.';
    'CAT 设置未完成，本次 Wires-X 启动已取消。'='CAT settings are incomplete. This Wires-X startup was cancelled.';
    'CAT 设置未完成，设备准备未能取消。'='CAT settings are incomplete; device preparation could not be cancelled.';
    'HRI 核心没有退出；取消本次 MAIN 调制/频率设置。'='The HRI core did not exit. Cancelled this MAIN mode/frequency setting.';
    '核心已停止；等待旧 CAT 查询收尾后再读取新状态。'='The core stopped. Waiting for the old CAT query to finish before reading the new state.';
    '旧电台查询仍在收尾；完成前不会发送 MAIN 设置。'='The previous radio query is still cleaning up. No MAIN setting will be sent until it finishes.';
    'HRI 已断开；没有执行 CAT 设置：'='HRI disconnected. CAT settings were not applied: ';
}
# Additional entries: one "source<TAB>English" pair per line. A source may contain {0}, {1} ... placeholders;
# such entries are compiled into anchored templates and every captured part is translated recursively,
# so dynamic values (IDs, ports, user names) stay verbatim while nested canonical messages are translated.
# "\n" stands for a line break. Entries already present in the hashtable above take precedence.
$script:WirexUiEnglishTextTsv = @'
无法创建或读取便携配置 config.json：{0}	Could not create or read the portable settings config.json: {0}
尚未设置	Not set
主窗口缺少控件 {0}。	The main window is missing control {0}.
设置页面地址无效。	The settings page address is invalid.
DMR ID 无效。	The DMR ID is invalid.
呼号尚未解析。	The callsign has not been resolved.
资料页面地址无效。	The profile page address is invalid.
呼号无效，无法打开 QRZ 资料页。	Invalid callsign; cannot open the QRZ page.
QRZ 资料页面地址无效。	The QRZ page address is invalid.
界面缺少控件 {0}。	The window is missing control {0}.
主控制台尚未创建。	The main console has not been created.
统一配置尚未加载。	Portable settings have not been loaded.
电台控制	Radio control
设备 {0}	Device {0}
正在检查已保存端点 · 	Checking saved endpoint · 
已保存端点当前未发现 · 	Saved endpoint not found · 
正在检查已保存 HRI 串口 · 	Checking saved HRI port · 
已保存串口当前未发现为 HRI · 	Saved port not found as HRI · 
HRI（不可用于 CAT）	HRI (not usable for CAT)
 · 推荐 CAT · 	 · Recommended CAT · 
 · 可手选 · 	 · Selectable · 
统一配置尚未加载，无法保存界面语言。	Portable settings have not been loaded; cannot save the interface language.
设备选择已核对	Device selection verified
桥接已启动	Bridge started
电台音频输出已就绪	Radio audio output ready
手咪开始发送	Microphone transmit started
手咪已松开，正在完成发送	Microphone released; finishing transmit
电台开始播放来话	Radio started playing the incoming call
本次来话来源标签已准备	Source label for this incoming call is ready
来话结束	Incoming call ended
单次发送到达时限，请松开手咪后再讲话	Transmit time limit reached; release the microphone before talking again
正在停止桥接	Stopping bridge
桥接已停止	Bridge stopped
桥接因错误停止	Bridge stopped due to an error
桥接遇到错误并已停止	Bridge hit an error and stopped
BM 未能建立连接	BM could not establish a connection
电台音频输出尚未就绪，来话未播放	Radio audio output is not ready; the incoming call was not played
发送未开始，当前设备尚未就绪	Transmit did not start; the device is not ready
本次发送未开始，请松开手咪后重新按下	Transmit did not start; release the microphone and press again
来话播放已停止	Incoming call playback stopped
核心尚未启动。	The core has not started.
单呼目标 {0}	Private target {0}
全部组呼	All groups
未选组呼	No groups selected
私呼关闭	Private calls off
指定私呼	Selected private calls
私呼转本机	Private calls to local
私呼无路由	Private calls not routed
无	None
私呼 {0}	Private {0}
音量增益必须是 1x 到 16x 的整数。	Audio gain must be a whole number from 1x to 16x.
已保存的音量增益超出可读取范围。	The saved audio gain is out of the readable range.
播放 {0} · 发送 {1}	Playback {0} · Transmit {1}
增益 {0}	Gain {0}
已保存：{0}	Saved: {0}
姓名	Name
国家	Country
州/省	State/Province
城市	City
地区：{0}	Location: {0}
Radio ID 单条查询	Radio ID lookup
本机缓存	Local cache
用户导入文件	User import file
资料来源：{0}	Source: {0}
更新时间：{0}	Updated: {0}
查询超时	Lookup timed out
网络查询失败	Network lookup failed
资料服务响应无效	Invalid profile service response
本机资料缓存保存失败	Could not save the local profile cache
资料查询队列已满	Profile lookup queue is full
资料模块不可用	Profile module unavailable
资料查询无法启动	Profile lookup could not start
资料查询结果无效	Invalid profile lookup result
资料查询清理失败	Profile lookup cleanup failed
资料服务返回 HTTP {0}	Profile service returned HTTP {0}
资料查询失败	Profile lookup failed
来源 DMR ID 无效	Invalid source DMR ID
私呼 至本机 DMR ID {0}	Private to local DMR ID {0}
组呼 TG {0}	Group TG {0}
{0} · {1} · 来源 {2}	{0} · {1} · from {2}
资料查询没有返回一条有效记录。	The profile lookup did not return exactly one valid record.
资料查询返回的来源 ID 与请求不一致。	The profile lookup returned a source ID that does not match the request.
资料查询兼容 ID 与请求不一致。	The profile lookup compatibility ID does not match the request.
资料查询状态无效。	Invalid profile lookup status.
查询已取消	Lookup cancelled
私呼	Private
本机 DMR ID {0}	Local DMR ID {0}
{0} · {1} {2} · 来源 {3}	{0} · {1} {2} · from {3}
来话历史去重需要有效 run_id 和接收代次。	Call history deduplication requires a valid run_id and receive generation.
历史记录呼叫类型无效。	Invalid call type in history record.
历史记录目标或 TS 无效。	Invalid target or TS in history record.
频道网络参数无效。	Invalid channel network parameters.
全国	Nationwide
中国鹦鹉	China Parrot
TG {0} TS{1}；静态组已读取。	TG {0} TS{1}; static group read back.
TG {0} TS{1}；本机已发送上一条激活请求，BM 当前动态组状态未知。	TG {0} TS{1}; a previous activation request was sent locally. BM dynamic group state is unknown.
{0}\n本机上次请求已发送；BM 当前动态组状态未知。点击可再次激活。	{0}\nThe last local request was sent; BM dynamic group state is unknown. Click to activate again.
TG {0} TS{1} 等待当前通话结束超时；没有发送激活请求。	TG {0} TS{1} timed out waiting for the current call to end; no activation request was sent.
TG {0} TS{1} 已由当前 BM 设备的静态组列表确认；无需激活。	TG {0} TS{1} is confirmed in the current BM static group list; activation is not needed.
TG {0} TS{1} 等待当前通话结束。	TG {0} TS{1} is queued until the current call ends.
更新频道	Update channels
频道目标状态未确认；停止完成前不能修改频道。	Channel target state is unconfirmed. Channels cannot be changed until the stop completes.
频道设置开始更新；排队已取消，没有发送激活请求。	Channel settings started updating. The queued request was cancelled; nothing was sent.
上一项频道设置仍在处理中。	The previous channel setting is still being processed.
核心尚未报告当前频道状态。	The core has not reported the current channel state.
频道列表中的PTT目标无效。	The TX target in the channel list is invalid.
正在{0}；等待核心确认当前频道设置。	Applying {0}; waiting for the core to confirm channel settings.
{0}已保存。	{0} saved.
频道目标状态未能确认	Channel target state could not be confirmed
本机正在安全停止；排队取消，没有发送激活请求。	Stopping safely. The queued request was cancelled; nothing was sent.
{0}；正在停止连接，原频道和 PTT 配置会保留。	{0}. Stopping the connection; the previous channel and TX target settings will be kept.
频道目标未能确认；停止完成后可手动重新连接。	Channel target could not be confirmed. Reconnect manually after the stop completes.
核心已退出；正在清理本次连接后保留原频道配置。	The core exited. Cleaning up this connection; the previous channel settings will be kept.
无法确认核心已停止；频道操作保持锁定，请重试停止。	Could not confirm the core stopped. Channel actions remain locked; try stopping again.
核心已停止；原频道配置保留，可手动重新连接。	The core stopped. The previous channel settings were kept; you can reconnect manually.
{0}；原频道和 PTT 配置已保留。	{0}. The previous channel and TX target settings were kept.
PTT目标已应用，但新的监听频道未能提交	TX target applied, but the new listening channels could not be committed
核心已确认新的频道与 PTT 目标，界面已更新；本机配置文件保存失败：{0}	The core confirmed the new channels and TX target and the UI was updated, but the local settings file could not be saved: {0}
{0}已在当前连接生效并保存。	{0}: applied to the current connection and saved.
{0}已确认并保存	{0}: confirmed and saved
请选择组呼或单呼类型。	Select the Group or Private type.
频道列表已包含相同网络目标。	The channel list already contains the same network target.
频道列表已达256项上限。	The channel list has reached the 256-entry limit.
加入频道	Add channel
正在移除最后一个频道；排队取消，没有发送激活请求。	Removing the last channel. The queued request was cancelled; nothing was sent.
正在停止连接以移除最后一个频道。	Stopping the connection to remove the last channel.
{0}仅对当前界面会话生效。	{0}: applies to the current UI session only.
PTT频道参数无效。	Invalid TX channel parameters.
PTT目标必须是当前频道列表中的频道。	The TX target must be a channel in the current channel list.
切换PTT目标	Change TX target
当前没有已准备的 HRI 来源标签	No HRI source label is prepared
等待本次运行报告	Waiting for this session's report
状态已过期，旧标签已清除	Status expired; the old label was cleared
本次运行已结束	This session has ended
当前核心未提供来源标签字段	The current core does not provide a source label field
{0} · 已准备	{0} · Ready
FTX-1 屏幕：未知	FTX-1 display: Unknown
UI 运行日志保留上限必须大于或等于零。	UI run log retention limits must be zero or greater.
UI 运行目录不在本机配置目录内。	The UI run directory is not inside the local settings directory.
UI 运行目录是重解析点，拒绝清理。	The UI run directory is a reparse point; cleanup refused.
待清理的 UI 运行目录越界。	The UI run directory to clean is out of bounds.
核心返回的控制消息超过 128 KiB 限制。	A control message from the core exceeds the 128 KiB limit.
控制协议 v2 JSON 无法解析。	Could not parse control protocol v2 JSON.
控制协议 v2 帧头无效。	Invalid control protocol v2 frame header.
routing_state 字段、run_id、control_seq 或 routing snapshot 无效。	Invalid routing_state fields, run_id, control_seq, or routing snapshot.
control_ready 字段或支持命令列表无效。	Invalid control_ready fields or supported command list.
隔离控制运行不得声明 BM 连接命令。	An isolated control run must not declare BM connection commands.
control_ready 的进程、run_id 或 control_seq 与当前子进程不匹配。	The control_ready process, run_id, or control_seq does not match the current child process.
control_ready.run_id 的 PID 前缀与 process_id 不符。	The PID prefix of control_ready.run_id does not match process_id.
控制协议 v2 只接受 control_ready 或 control_result。	Control protocol v2 only accepts control_ready or control_result.
control_result.command 无效。	Invalid control_result.command.
control_result.result 无效。	Invalid control_result.result.
control_result 字段、run_id 或 control_seq 无效。	Invalid control_result fields, run_id, or control_seq.
radio_identity.cache_upsert 的 request_id 无效。	Invalid request_id for radio_identity.cache_upsert.
audio.gains.set 的 request_id 无效。	Invalid request_id for audio.gains.set.
control_result.request_id 无效。	Invalid control_result.request_id.
control_result.error 必须是字符串。	control_result.error must be a string.
BM accepted 响应不得包含 error。	A BM accepted response must not include error.
BM rejected 响应必须说明 error。	A BM rejected response must include error.
拒绝或不支持的响应必须说明 error。	A rejected or unsupported response must include error.
初始确认返回的命令列表无效。	The initial confirmation returned an invalid command list.
状态查询结果无效。	Invalid status query result.
停止请求没有得到确认。	The stop request was not confirmed.
路由设置结果无效。	Invalid routing setting result.
动态组激活结果字段无效。	Invalid dynamic group activation result fields.
音量增益应用结果字段无效。	Invalid audio gain result fields.
BM连接响应状态字段无效。	Invalid BM connection response status fields.
BM连接拒绝原因无效。	Invalid BM connection rejection reason.
BM连接不支持响应原因无效。	Invalid BM connection unsupported reason.
拒绝响应的 error 字段无效。	Invalid error field in rejection response.
本机控制：等待	Local control: waiting
Native 运行会话已结束；排队取消，没有发送激活请求。	The Native session ended. The queued request was cancelled; nothing was sent.
请连接核心与 BM 后操作动态组。	Connect the core and BM before using dynamic groups.
BM 连接失败，请检查配置后重试。	BM connection failed. Check the settings and try again.
BM 主站仍在解析，串口保持连接。	The BM server is still being resolved; the serial port stays connected.
BM 网络仍在清理，串口保持连接。	BM network is still cleaning up; the serial port stays connected.
BM 状态未确认，串口保持连接。	BM state is unconfirmed; the serial port stays connected.
BM 会话仍未停止，串口保持连接。	The BM session has not stopped yet; the serial port stays connected.
核心返回过多控制消息；当前状态尚未确认。	The core returned too many control messages; the current state is unconfirmed.
控制协议事件队列溢出	Control protocol event queue overflow
核心控制状态校验失败：{0}	Core control state validation failed: {0}
控制协议帧校验失败	Control protocol frame validation failed
核心在确认设置能力前发送了状态；请重新连接。	The core sent status before confirming settings capabilities. Reconnect.
核心设置状态无效：{0}	Invalid core settings state: {0}
无法确认本次核心运行身份	Could not confirm the identity of this core run
无法与核心确认设置；请检查连接状态。	Could not confirm settings with the core. Check the connection.
核心返回了未知的控制结果	The core returned an unknown control result
核心返回了不匹配的身份缓存确认	The core returned a mismatched identity cache confirmation
核心返回了不匹配的 BM 连接确认	The core returned a mismatched BM connection confirmation
本地频道诊断中的组呼激活请求未获确认。	The group activation request in the local channel diagnostic was not confirmed.
激活失败：本机媒体仍忙。	Activation failed: local media is still busy.
激活失败：本机控制、BM连接或传输未就绪。	Activation failed: local control, BM connection, or transport is not ready.
激活失败：组号或时隙无效。	Activation failed: invalid group or timeslot.
TG 4000 是断开组，不能激活。	TG 4000 is the disconnect group and cannot be activated.
激活失败：本机没有发出完整请求。	Activation failed: the local side did not send a complete request.
激活失败：请求只发送了一部分；本机没有重试。	Activation failed: the request was only partially sent; it was not retried.
激活失败：本机没有确认完整发送。	Activation failed: the local side did not confirm a complete send.
激活失败：{0}	Activation failed: {0}
设置操作失败：{0}	Setting operation failed: {0}
核心拒绝了本机收听规则 TG {0}：{1}	The core rejected the local listening rule TG {0}: {1}
核心明确拒绝新的 PTT 目标；原频道和配置保留：{0}	The core rejected the new TX target; the previous channels and settings were kept: {0}
PTT目标已应用，但监听频道更新遭到拒绝：{0}	TX target applied, but the listening channel update was rejected: {0}
核心明确拒绝新的监听频道；原频道和配置保留：{0}	The core rejected the new listening channels; the previous channels and settings were kept: {0}
核心拒绝了这项设置；正在读取当前运行设置。	The core rejected this setting. Reading the current runtime settings.
核心拒绝了这项设置；正在读取当前运行设置。{0}	The core rejected this setting. Reading the current runtime settings. {0}
核心未接受下一起呼目标设置：{0}	The core did not accept the next TX target: {0}
核心未接受 TG {0} 起呼目标设置：{1}	The core did not accept TG {0} as the TX target: {1}
核心拒绝接收路由设置	The core rejected the routing settings
当前设置读取失败；没有自动重发任何更改。	Could not read the current settings; no changes were resent automatically.
当前设置读取失败；没有自动重发任何更改。{0}	Could not read the current settings; no changes were resent automatically. {0}
本机频道更新命令遭到核心拒绝。	The core rejected the local channel update command.
本机控制已确认{0}	Local control confirmed{0}
 · 仅本地诊断	 · Local diagnostic only
 · 本机路由设置可用	 · Local routing settings available
 · 仅本地诊断 · 本机路由设置可用	 · Local diagnostic only · Local routing settings available
频道添加流程触发了意外组呼激活。	The add-channel flow triggered an unexpected group activation.
频道动态组激活没有返回预期的两帧内存发送结果。	Channel dynamic group activation did not return the expected two-frame in-memory send result.
本机频道与组呼诊断已完成，正在复读状态。	Local channel and group call diagnostic finished; reading state again.
TG {0} TS{1}：本机 Native 结果未确认两帧已发送；请检查连接后手动重试。	TG {0} TS{1}: local Native did not confirm both frames were sent. Check the connection and retry manually.
激活请求已发送	Activation request sent
Native 确认激活请求已发送两帧 · TG {0} TS{1}	Native confirmed both activation frames were sent · TG {0} TS{1}
TG {0} TS{1} 激活请求已发送。	TG {0} TS{1} activation request sent.
读取本机缓存的发送结果；没有再次发送帧	Read the locally cached send result; no frames were resent
仅本机诊断：未连接 BM、HRI 或音频设备	Local diagnostic only: BM, HRI, and audio devices are not connected
重放摘要	Replay summary
状态摘要	Status summary
{0}：{1} / {2} · media_seq {3}	{0}: {1} / {2} · media_seq {3}
核心返回了不匹配的增益确认	The core returned a mismatched gain confirmation
核心未提供本机多路由设置	The core does not provide local multi-route settings
收到的设置结果不属于当前请求；正在读取当前设置。	The received settings result does not belong to the current request. Reading the current settings.
频道路由返回重复结果，无法确认本次目标状态	Channel routing returned a duplicate result; the target state cannot be confirmed
该设置请求已处理过；没有再次保存，正在读取当前设置。	This settings request was already processed. It was not saved again; reading the current settings.
核心返回的频道目标状态无效	The core returned an invalid channel target state
核心返回的设置状态无效：{0}	The core returned an invalid settings state: {0}
核心返回的频道目标状态未能应用	The channel target state returned by the core could not be applied
当前运行设置已刷新；未确认的草稿仍在设置中保留，未自动重发。	Current runtime settings refreshed. The unconfirmed draft is kept in settings and was not resent.
下一起呼目标设置已确认	Next TX target confirmed
设置已应用	Settings applied
核心已确认 TG {0} 为下一起呼叫目标；没有发起呼叫，收听规则未变。	The core confirmed TG {0} as the next TX target. No call was started and listening rules are unchanged.
本机收听规则已由核心确认：TG {0}；没有发送动态组激活请求。	The core confirmed the local listening rule: TG {0}. No dynamic group activation request was sent.
预检 routing-state.json 缺失或超过 64 KiB。	Preflight routing-state.json is missing or larger than 64 KiB.
预检 routing-state.json JSON 无效。	Preflight routing-state.json contains invalid JSON.
预检 routing-state.json schema 1 或 RX 策略无效。	Preflight routing-state.json has an invalid schema 1 or RX policy.
预检 routing-state.json 的 TX 目标与本次连接配置不一致。	The TX target in preflight routing-state.json does not match this connection's settings.
设备预检返回的启动参数结构无效。	Device preflight returned an invalid launch argument structure.
本次启动目录不属于 UI 创建的 GUID 运行目录。	This launch directory is not a GUID run directory created by the UI.
设备预检返回的 native 核心与当前所选便携目录不符。	The native core returned by device preflight does not match the selected portable directory.
设备预检返回的状态文件不属于本次启动目录。	The status file returned by device preflight is not in this launch directory.
routing-state.json 必须位于本次 GUID 运行目录中。	routing-state.json must be in this session's GUID run directory.
设备预检返回的启动参数不完整。	Device preflight returned incomplete launch arguments.
设备预检返回了重复或不受支持的启动参数。	Device preflight returned duplicate or unsupported launch arguments.
设备预检返回的启动参数缺少值。	Device preflight returned a launch argument without a value.
设备预检缺少 BM 密码文件参数。	Device preflight is missing the BM password file argument.
设备预检的 BM 启动模式与本次连接请求不一致。	The device preflight BM launch mode does not match this connection request.
设备预检返回的发射呼叫类型无效。	Device preflight returned an invalid TX call type.
设备预检必须启用 UI 控制协议 v2。	Device preflight must enable UI control protocol v2.
设备预检返回的状态参数缺少路径。	The status argument returned by device preflight has no path.
设备预检返回的 routing-state-file 参数缺少路径。	The routing-state-file argument returned by device preflight has no path.
设备预检返回的启动参数与状态或 routing-state 文件路径不一致。	Device preflight launch arguments do not match the status or routing-state file paths.
未能启动音频设备查询进程。	Could not start the audio device query process.
无法停止音频设备查询进程。	Could not stop the audio device query process.
native 音频设备查询失败。	Native audio device query failed.
native 音频设备查询必须只输出一行 JSON。	The native audio device query must output exactly one line of JSON.
native 音频设备列表格式无效。	Invalid native audio device list format.
native 音频设备列表包含无效项目。	The native audio device list contains invalid entries.
native 音频设备列表包含重复 WinMM ID。	The native audio device list contains duplicate WinMM IDs.
native 音频设备列表包含重复稳定端点标识。	The native audio device list contains duplicate stable endpoint IDs.
本地协议诊断：未查询真实串口或音频设备。	Local protocol diagnostic: real serial ports and audio devices were not queried.
正在停止上次设备查询，随后刷新串口和音频列表。	Stopping the previous device query, then refreshing serial port and audio lists.
正在读取串口与音频设备列表。	Reading serial port and audio device lists.
测试设备 Hook 返回了无效状态。	The test device hook returned an invalid status.
串口枚举 Hook 返回了无效结果。	The serial port enumeration hook returned an invalid result.
音频查询 Hook 返回了无效结果。	The audio query hook returned an invalid result.
音频查询 Hook 缺少 wave_inputs 或 wave_outputs 数组。	The audio query hook is missing the wave_inputs or wave_outputs array.
设备选项缺少显示标签或稳定值。	A device option is missing a display label or stable value.
当前设备选择没有对应的列表项。	The current device selection has no matching list item.
串口与音频设备读取失败。	Could not read serial ports and audio devices.
串口设备结果缺少 serial_ports 或 hri_ports 数组。	The serial device result is missing the serial_ports or hri_ports array.
音频设备结果缺少 wave_inputs 或 wave_outputs 数组。	The audio device result is missing the wave_inputs or wave_outputs array.
串口 {0}	Serial ports {0}
串口不可用	Serial ports unavailable
音频 {0}/{1}	Audio {0}/{1}
音频不可用	Audio unavailable
串口设备查询失败	Serial port query failed
音频设备查询失败	Audio device query failed
串口设备查询失败；音频设备查询失败	Serial port query failed; audio device query failed
串口设备查询未能及时停止。	The serial port query did not stop in time.
音频设备查询超过 10 秒。	The audio device query took longer than 10 seconds.
串口设备查询超过 25 秒。	The serial port query took longer than 25 seconds.
查询已取消。	Query cancelled.
串口设备查询没有返回有效列表。	The serial port query did not return a valid list.
串口设备列表结构无效。	Invalid serial port list structure.
串口数据源均未能读取。	None of the serial port sources could be read.
音频查询未返回结果。	The audio query returned no result.
串口查询未返回结果。	The serial port query returned no result.
正在读取当前增益	Reading current gain
运行增益已确认；本机配置保存失败。	Runtime gain confirmed, but the local settings could not be saved.
已应用	Applied
运行增益 revision 已达上限；请重新连接。	The runtime gain revision reached its limit. Reconnect.
正在应用	Applying
增益命令未送达；正在读取当前值。	The gain command was not delivered. Reading the current value.
等待应用	Waiting to apply
增益确认与当前请求不匹配；正在读取当前值。	The gain confirmation does not match the current request. Reading the current value.
已确认上一组增益	Previous gain values confirmed
增益命令未应用；正在读取当前值。	The gain command was not applied. Reading the current value.
已读取当前增益	Current gain read
增益确认超时；正在读取当前值。	Gain confirmation timed out. Reading the current value.
当前设置未能刷新；为避免覆盖运行状态，路由修改已锁定。请重新连接。	Could not refresh the current settings. Routing changes are locked to avoid overwriting runtime state. Reconnect.
频道激活组按钮未启用。	The channel Join button is not enabled.
没有找到本机诊断频道的激活组按钮。	The Join button for the local diagnostic channel was not found.
隔离频道诊断无法通过主窗口频道添加流程启动。	The isolated channel diagnostic could not start through the main window add-channel flow.
本地Native IPC确认添加监听频道后原PTT目标保持不变，并验证组呼激活仅通过内存接收器。	Local Native IPC confirmed the TX target was unchanged after adding a listening channel, and verified that group activation used only the in-memory receiver.
隔离频道诊断未能完成Native状态确认。	The isolated channel diagnostic could not complete Native state confirmation.
正在检查本次连接配置和设备。	Checking this connection's settings and devices.
上一次连接的临时材料尚未清理，不能覆盖后重新连接。	Temporary files from the previous connection have not been cleaned up; cannot overwrite them to reconnect.
请填写有效的连接信息，并至少加入一个频道。	Enter valid connection details and add at least one channel.
UiTestFixture 禁止启动真实核心；测试需注入 NativeSupervisorFactory。	UiTestFixture must not start the real core; tests must inject NativeSupervisorFactory.
NativeSupervisorFactory 必须返回包含 HasExited 属性的对象。	NativeSupervisorFactory must return an object with a HasExited property.
测试连接	Test connection
隔离 WPF 测试会话	Isolated WPF test session
本地路由诊断只接受隔离测试配置 Source ID 1。	The local routing diagnostic only accepts the isolated test settings with Source ID 1.
本机路由诊断（未连接电台或 BM）	Local routing diagnostic (radio and BM not connected)
路由诊断：未连接电台、BM、音频或 RF；以下状态只来自本机核心。	Routing diagnostic: radio, BM, audio, and RF are not connected; the status below comes only from the local core.
本机诊断	Local diagnostic
正在测试本机路由控制管道。	Testing the local routing control pipe.
本地协议诊断未启动 BrandMeister。	The local protocol diagnostic did not start BrandMeister.
本地协议诊断未打开 HRI 或音频设备。	The local protocol diagnostic did not open HRI or audio devices.
路由诊断模式；没有打开串口、音频、BM 或 RF。	Routing diagnostic mode; serial ports, audio, BM, and RF were not opened.
等待本机核心确认	Waiting for local core confirmation
请在 BM 密码框中输入密码后保存。	Enter the password in the BM password box, then save.
已清理 {0} 个已结束运行目录	Cleaned up {0} finished run directories
有已结束运行记录未能清理	Some finished run records could not be cleaned up
正在枚举本机设备并核对音频端点	Enumerating local devices and checking audio endpoints
连接前设备查询在后台执行	Pre-connect device query is running in the background
连接准备失败：{0}	Connection preparation failed: {0}
请打开设置并检查连接参数、密码文件和设备选择。	Open settings and check connection parameters, password file, and device selection.
连接准备失败	Connection preparation failed
本次连接的临时目录不存在。	The temporary directory for this connection does not exist.
设备预检失败。	Device precheck failed.
设备预检没有生成启动参数。	Device precheck produced no launch parameters.
运行中	Running
请打开设置检查配置，再重新启动。	Open settings to check the configuration, then restart.
BM 登录等待超时	BM login timed out
BM 认证等待超时	BM authentication timed out
BM 配置响应超时	BM config response timed out
BM 参数响应超时	BM options response timed out
BM 心跳响应超时	BM heartbeat response timed out
BM 拒绝连接	BM rejected the connection
BM 关闭连接	BM closed the connection
BM 响应格式无效	Invalid BM response format
收到无法识别的 BM 响应	Received an unrecognized BM response
BM 对端 ID 不匹配	BM peer ID mismatch
BM 认证失败	BM authentication failed
BM 接收队列已满	BM inbound queue full
BM 发送队列已满	BM outbound queue full
BM 网络连接中断	BM network connection lost
BM 连接参数无效	Invalid BM connection parameters
BM 返回未知错误	BM returned an unknown error
已收到 BM 登录确认。	BM login confirmed.
等待 BM 登录确认。	Waiting for BM login confirmation.
串口：{0} · HRI：{1} · 电台音频：{2}	Serial port: {0} · HRI: {1} · Radio audio: {2}
已打开	Open
未打开	Not open
就绪	Ready
未就绪	Not ready
已确认	Confirmed
未确认	Unconfirmed
双向流已打开	Both streams open
单路流已打开	One stream open
端点已核验	Endpoints verified
最近来话 · 目标 {0} · {1}	Last incoming call · Target {0} · {1}
状态更新于 {0}	Status updated at {0}
核心状态不再空闲，已请求取消电台功率设置；读回确认前结果未知。	The core is no longer idle, so cancelling the radio power setting was requested. The result is unknown until readback confirms it.
状态行超过大小限制，已跳过	Status line exceeded the size limit and was skipped
读取运行状态失败	Failed to read run status
核心空闲状态已过期，已请求取消电台功率设置；读回确认前结果未知。	The core idle state is stale, so cancelling the radio power setting was requested. The result is unknown until readback confirms it.
状态过期	Status stale
正在停止连接；排队取消，没有发送激活请求。	Stopping the connection; queue cancelled. No activation request was sent.
正在取消设备检查并退出。	Cancelling the device check and exiting.
正在切换运行会话；排队取消，没有发送激活请求。	Switching sessions; queue cancelled. No activation request was sent.
正在取消当前设备检查并使用所选目标重新连接。	Cancelling the current device check and reconnecting with the selected target.
设备关闭后将使用所选目标重新连接。	Will reconnect with the selected target after the devices close.
设备检查已取消	Device check cancelled
核心准备已取消；串口保持断开。	Core preparation cancelled; serial ports remain disconnected.
设备检查停止超时，正在关闭界面	Device check stop timed out; closing the window
Wires-X/HRI 与 CAT 串口均已断开。	Wires-X/HRI and CAT serial ports are both disconnected.
停止未完成	Stop incomplete
核心仍在运行；请再次选择停止并退出。	The core is still running. Choose Stop and exit again.
桥接核心尚未退出。	The bridge core has not exited yet.
HRI 会话已停止；正在验证 CAT 状态。	HRI session stopped; verifying CAT state.
断开后的 CAT 请求类型无效。	Invalid post-disconnect CAT request type.
当前连接已停止，正在连接所选目标。	Current connection stopped; connecting to the selected target.
HRI 会话已停止；没有待执行的 MAIN VFO 设置。	HRI session stopped; no pending MAIN VFO setting.
连接已停止；可按所选目标重新连接。	Connection stopped. You can reconnect with the selected target.
核心仍在运行；频道和 PTT 操作保持锁定，请重试停止。	The core is still running; channel and PTT actions stay locked. Retry stopping.
核心仍在运行；最后一个频道没有删除。	The core is still running; the last channel was not removed.
频道更新没有完整确认；连接已停止，原频道和 PTT 配置保留。可手动重新连接。	The channel update was not fully confirmed. The connection stopped and the original channel and PTT settings were kept. You can reconnect manually.
连接已停止；原频道配置保留，可手动重新连接。	Connection stopped; the original channel settings were kept. You can reconnect manually.
连接已停止，但保存频道列表失败：{0}	Connection stopped, but saving the channel list failed: {0}
控制协议：本次进程已退出	Control protocol: this process has exited
核心进程已退出，退出码 {0}。CAT会话已收尾。	Core process exited with code {0}. The CAT session was closed out.
核心进程已退出，退出码 {0}	Core process exited with code {0}
核心在频道设置确认前退出；未确认的变更已丢弃，原频道配置保留。	The core exited before confirming channel settings. Unconfirmed changes were discarded and the original channel settings were kept.
频道更新未确认；原配置保留，可手动重新连接。	Channel update unconfirmed; the original settings were kept. You can reconnect manually.
电台控制操作收尾失败：{0}	Failed to finish the radio control operation: {0}
电台状态轮询失败：{0}	Radio status polling failed: {0}
等待本机 Native 结果超时；没有确认是否发送，请检查状态后手动重试。	Timed out waiting for the local Native result; it is not confirmed whether it was sent. Check the status and retry manually.
PTT目标等待核心确认超时	TX target timed out waiting for core confirmation
PTT目标已应用，但监听频道等待核心确认超时	TX target applied, but listening channels timed out waiting for core confirmation
等待应用设置超时；正在刷新当前运行设置，不会自动重发。未确认的草稿已保留。	Timed out waiting for settings to apply. Refreshing the current settings without resending automatically. The unconfirmed draft was kept.
等待设置超时，正在刷新当前状态	Settings timed out; refreshing current status
路由设置等待超时；未自动重发	Routing settings timed out; not resent automatically
核心确认等待超时；当前确认目标和活动通话保持原状。正在刷新当前策略。	Timed out waiting for core confirmation. The confirmed target and active call are unchanged. Refreshing the current policy.
起呼目标请求等待超时；没有发起呼叫。正在刷新核心策略。	Call target request timed out; no call was started. Refreshing the core policy.
{0} 的选中项没有显示纯文本标签。	The selected item of {0} does not show a plain-text label.
{0} 的选中项没有保留独立的稳定值元数据。	The selected item of {0} does not keep separate stable value metadata.
{0} 的模板缺少选中项文本显示区域。	The template of {0} has no selected-item text area.
{0} 选中框视觉树没有显示设备标签。	The selection box visual tree of {0} does not show the device label.
{0} 下拉列表没有创建视觉树。	The drop-down list of {0} did not create a visual tree.
{0} 下拉项视觉树没有显示纯文本标签。	The drop-down item visual tree of {0} does not show plain-text labels.
{0} 视觉树泄漏了 PowerShell 对象元数据。	The visual tree of {0} exposes PowerShell object metadata.
本机 DMR ID	Local DMR ID
请先填写本机 DMR ID，再选择设备编号。	Enter the local DMR ID before choosing a device number.
请填写两位设备编号（00–99），再保存本机 DMR ID。	Enter a two-digit device number (00–99) before saving the local DMR ID.
设备编号必须是两位数字（00–99）。	The device number must be two digits (00–99).
请等待当前设备操作结束后再保存。	Wait for the current device operation to finish before saving.
配置尚未加载；请关闭并重新打开设置窗口后重试。	Settings are not loaded yet. Close and reopen the settings window, then try again.
Wires-X HRI 串口	Wires-X HRI port
{0}选择无效；请刷新设备列表并重新选择。	Invalid {0} selection. Refresh the device list and select again.
音频输入	Audio input
音频输出	Audio output
{0}端点选择无效；请刷新设备列表并重新选择。	Invalid {0} endpoint selection. Refresh the device list and select again.
connection 字段格式无效。	Invalid connection field format.
呼号、BM 服务器或认证字段格式无效；请检查对应输入框。	Invalid callsign, BM server, or authentication field. Check the corresponding inputs.
CAT 串口设置无效；停止位固定为 Two。	Invalid CAT serial settings; stop bits are fixed at Two.
CAT 波特率设置无效；请选择列表中的波特率。	Invalid CAT baud rate. Choose a baud rate from the list.
配置内容无效；当前文件未被覆盖，请检查连接、设备和频道设置。	Invalid settings; the current file was not overwritten. Check connection, device, and channel settings.
无法写入配置；请检查用户配置目录的访问权限。	Cannot write settings. Check access permissions for the user settings directory.
无法写入配置文件；请检查目录权限和磁盘空间。	Cannot write the settings file. Check directory permissions and disk space.
设置未保存（{0}）；现有配置已保留，请检查输入字段或配置目录。	Settings not saved ({0}). The existing settings were kept. Check the input fields or settings directory.
CAT 串口 {0} 正在使用或释放中，不能同时启动 Wires-X。请断开 CAT 或更换 HRI 串口。	CAT port {0} is in use or being released, so Wires-X cannot start at the same time. Disconnect CAT or choose a different HRI port.
配置尚未通过校验；请检查呼号、Gateway ID、本机 ID 和频道。	Settings failed validation. Check callsign, Gateway ID, local ID, and channels.
配置尚未通过校验；请检查 BM 参数、呼号、Gateway ID 和本机 ID。	Settings failed validation. Check BM parameters, callsign, Gateway ID, and local ID.
当前核心不支持 BM 独立连接；请更新核心后重试。	The current core does not support standalone BM connections. Update the core and try again.
正在应用新的 BM 连接配置；排队取消，没有发送激活请求。	Applying new BM connection settings; queue cancelled. No activation request was sent.
正在应用新的 BM 连接配置；CAT 保持连接。	Applying new BM connection settings; CAT stays connected.
正在读取当前 BM 配置状态。	Reading current BM settings state.
正在停止核心；排队取消，没有发送激活请求。	Stopping the core; queue cancelled. No activation request was sent.
串口和核心已断开。	Serial ports and core disconnected.
正在断开串口与核心；排队取消，没有发送激活请求。	Disconnecting serial ports and core; queue cancelled. No activation request was sent.
正在取消核心准备并收好串口。	Cancelling core preparation and releasing serial ports.
正在读取 BM 状态，确认网络关闭后再停止 HRI。	Reading BM status; HRI will stop after the network is confirmed closed.
设备操作中，配置暂时锁定	Device operation in progress; settings temporarily locked
BM连接中，传输配置已锁定	BM connected; transport settings locked
HRI/音频设备已占用；BM配置可单独保存	HRI/audio devices in use; BM settings can be saved separately
配置保存失败：{0}	Failed to save settings: {0}
{0} 必须是有效的无符号整数。	{0} must be a valid unsigned integer.
音量设置保存失败。	Failed to save audio settings.
临时材料目录不符合本次会话路径约定。	The temporary files directory does not match this session's path convention.
临时材料目录不能是重解析点。	The temporary files directory cannot be a reparse point.
临时材料目录仍然存在。	The temporary files directory still exists.
本次会话临时材料清理失败；关闭或重新连接前会再次尝试	Failed to clean up this session's temporary files; will retry before closing or reconnecting
核心返回的路由设置格式无效。	The core returned invalid routing settings.
核心返回的本机 ID 与统一配置不一致。	The local ID returned by the core does not match the portable settings.
频道目标状态未确认；停止完成前不能提交路由修改。	Channel target state is unconfirmed; routing changes cannot be submitted until stop completes.
当前核心状态不能替换监听频道。	Listening channels cannot be replaced in the current core state.
由频道生成的收听策略无效。	The listening policy generated from channels is invalid.
PTT频道设置无效。	Invalid TX channel setting.
命令发送失败。	Failed to send command.
历史呼叫 {0}	History call {0}
本次连接的临时材料仍被占用；清理完成后再关闭。	This connection's temporary files are still in use; close after cleanup finishes.
隔离 UI 测试没有启动设备或网络。	Isolated UI test did not start devices or network.
离线预览：没有连接设备或网络。	Offline preview: no devices or network connected.
请填写呼号、Gateway ID、本机 DMR ID，并加入至少一个频道。	Enter callsign, Gateway ID, and local DMR ID, and add at least one channel.
配置需要修正。	Settings need correction.
请检查统一配置和设备选择。	Check portable settings and device selection.
串口取消请求失败	Serial port cancel request failed
CAT端口未就绪	CAT port not ready
CAT端口未枚举	CAT port not enumerated
HRI（不可用于 CAT） · {0}	HRI (not usable for CAT) · {0}
{0} · 推荐 CAT · {1}	{0} · Recommended CAT · {1}
{0} · 可手选 · {1}	{0} · Manual selection · {1}
当前CAT读值；超出当前功率路径上限 {0} W	Current CAT reading; exceeds the current power path limit of {0} W
超出当前功率路径上限 {0} W	Exceeds the current power path limit of {0} W
当前CAT读值	Current CAT reading
目标功率 {0} W 超出当前路径上限 {1} W；请重新选择有效功率。	Target power {0} W exceeds the current path limit of {1} W. Choose a valid power level.
请选择有效 CAT 串口和波特率。	Select a valid CAT port and baud rate.
CAT-1 与当前 HRI 串口不能共用。	CAT-1 cannot share the current HRI serial port.
当前隔离界面禁止 CAT 串口操作。	CAT serial port operations are disabled in this isolated UI.
已有一组 CAT 设置正在执行。	A CAT settings operation is already running.
CAT 身份、TX=0、端口或读取时间未通过检查；没有发送设置。	CAT identity, TX=0, port, or read time failed checks; no setting was sent.
新鲜 CAT 读取没有返回完整的 MAIN 模式、频率和功率能力；没有发送设置。	The fresh CAT read did not return complete MAIN mode, frequency, and power capability; no setting was sent.
新读到的功率路径只允许 5–{0} W；请在此范围内选择后重新应用。	The newly read power path allows only 5–{0} W. Choose a value in this range and apply again.
新鲜 CAT 读取中的字段格式或范围无效；没有发送设置。	The fresh CAT read has an invalid field format or range; no setting was sent.
MAIN 频率	MAIN frequency
本次 CAT 读回与目标相同	CAT readback matches the target
CAT 读回或串口收尾未确认	CAT readback or serial close-out unconfirmed
CAT 用户动作类型无效。	Invalid CAT user action type.
FTX-1 CAT-1 模块当前不可用。	The FTX-1 CAT-1 module is currently unavailable.
另一项 CAT-1 操作尚未结束。	Another CAT-1 operation has not finished.
核心正在准备或取消连接；请等待设备检查完成。	The core is preparing or cancelling a connection. Wait for the device check to finish.
请选择或手动输入 CAT 串口 COM1–COM999。	Select or enter a CAT port COM1–COM999.
CAT 串口必须是 COM1 到 COM999。	CAT port must be COM1 to COM999.
所选串口已识别为 HRI，不能用于 CAT。	The selected port is identified as HRI and cannot be used for CAT.
CAT-1 与 HRI 不能共用 {0}。	CAT-1 and HRI cannot share {0}.
核心状态未确认电台空闲；设置操作已取消。	Core state did not confirm the radio is idle; the setting was cancelled.
单字段 CAT 写入只能由统一的模式、频率、功率应用流程启动。	Single-field CAT writes can only be started by the combined mode, frequency, and power apply flow.
冻结的 MAIN 模式已变化；拒绝发送。	The fixed MAIN mode changed; send refused.
冻结的 MAIN 频率已变化；拒绝发送。	The fixed MAIN frequency changed; send refused.
冻结的目标功率已变化；拒绝发送。	The fixed target power changed; send refused.
CAT-1 串口格式不在模块允许范围内。	CAT-1 serial format is outside the range the module allows.
CAT会话已变化；丢弃旧worker结果。	CAT session changed; discarded the old worker result.
串口选择已变化；丢弃了旧读取结果。	Serial port selection changed; discarded the old read result.
串口关闭状态未确认；本次结果未知。	Serial port close state unconfirmed; the result is unknown.
本次设置未获确认。	This setting was not confirmed.
返回的数据或端口身份没有通过检查。	Returned data or port identity failed checks.
CAT查询未确认	CAT query unconfirmed
断开后的 CAT 设置类型无效。	Invalid post-disconnect CAT setting type.
BM 静态组界面尚未初始化。	BM static group window is not initialized.
BM 静态组界面缺少控件 {0}。	BM static group window is missing control {0}.
已读取 {0} 条 BM 静态组；设备状态 {1}。	Read {0} BM static groups; device status {1}.
已读取 {0} 条 BM 静态组；设备状态 {1}，添加已禁用。	Read {0} BM static groups; device status {1}; adding is disabled.
{0} 的应用功率范围为 5-{1} W；不会自动钳位。	The app power range for {0} is 5-{1} W; values are not clamped automatically.
Fake/serial transport 缺少 {0} 方法。	Fake/serial transport is missing method {0}.
Fake/serial transport 的 {0} 必须是 ScriptBlock。	Fake/serial transport {0} must be a ScriptBlock.
CAT 响应含非 ASCII 可打印字节。	CAT response contains non-printable-ASCII bytes.
CAT 响应超过帧长限制。	CAT response exceeds the frame length limit.
CAT 命令 {0} 在 session deadline 内没有收到匹配响应。	CAT command {0} got no matching response within the session deadline.
FTX-1 CAT 在请求 {0} 时返回错误帧 ?;。	FTX-1 CAT returned error frame ?; for request {0}.
FTX-1 CAT 返回语法无效的完整帧：{0}	FTX-1 CAT returned a complete frame with invalid syntax: {0}
FTX-1 CAT 响应无效：{0}	Invalid FTX-1 CAT response: {0}
CAT 响应侧别与请求不符：{0}	CAT response side does not match the request: {0}
CAT-1 端口名不能为空。	CAT-1 port name cannot be empty.
CAT-1 端口与当前 HRI 端口相同；为避免两个协议共用串口，本次未打开端口。	The CAT-1 port is the same as the current HRI port. To avoid two protocols sharing a serial port, the port was not opened.
setMode 需要 Mode。	setMode requires Mode.
setPower 需要 PowerWatts。	setPower requires PowerWatts.
本应用接受5–50 W的期望值；不会自动钳位。	This app accepts a target of 5–50 W; values are not clamped automatically.
setFrequency 需要 FrequencyHz。	setFrequency requires FrequencyHz.
本版本只允许设置 MAIN 侧 FA 频率。	This version only allows setting the MAIN-side FA frequency.
MAIN FA 频率范围为 30,000–470,000,000 Hz；不会自动钳位。	MAIN FA frequency range is 30,000–470,000,000 Hz; values are not clamped automatically.
波特率不在 FTX-1 CAT 手册列出的选项内。	Baud rate is not among the options listed in the FTX-1 CAT manual.
当前功率路径 {0} 的应用范围为 5-{1} W；不会自动钳位。	The app range for current power path {0} is 5-{1} W; values are not clamped automatically.
{0} 串口关闭失败：{1}	{0} Serial port close failed: {1}
CAT 读回值与目标相符，但串口关闭失败；本次操作整体状态为 unknown：{0}	CAT readback matches the target, but closing the serial port failed; overall operation state is unknown: {0}
CAT 会话未能在时限内完成并关闭；本次不提供写入许可。	The CAT session did not finish and close in time; write permission is not granted.
无法打开 CAT-1 端口；端口可能被其他程序占用或访问被拒绝。	Cannot open the CAT-1 port. It may be in use by another program or access was denied.
CAT-1 串口读写失败；本次没有报告设置已生效。	CAT-1 serial port I/O failed; the setting was not reported as applied.
CAT 操作未成功完成；本次不提供写入许可。	CAT operation did not complete successfully; write permission is not granted.
配置 JSON 字段名不能使用转义写法。	Settings JSON field names cannot use escape sequences.
配置 JSON 存在重复字段。	Settings JSON has duplicate fields.
配置 JSON 对象结构无效。	Invalid settings JSON object structure.
配置 JSON 结构无效。	Invalid settings JSON structure.
{0} 数值无效。	{0} value is invalid.
{0} 超出允许范围。	{0} is out of range.
config.json 必须是 JSON 对象；原文件已保留。	config.json must be a JSON object; the original file was kept.
config.json 缺少必需字段；原文件已保留。	config.json is missing required fields; the original file was kept.
config.json 含有不完整字段组；原文件已保留。	config.json has an incomplete field group; the original file was kept.
便携配置必须是 JSON 对象。	Portable settings must be a JSON object.
便携配置版本不受支持。	Portable settings version is not supported.
便携配置 {0} 必须是对象。	Portable settings {0} must be an object.
便携配置 {0} 必须是有序数组。	Portable settings {0} must be an ordered array.
connection 缺少字段 {0}。	connection is missing field {0}.
devices.{0} 必须是 auto 或 COM1 到 COM999。	devices.{0} must be auto or COM1 to COM999.
devices.{0} 字段格式无效。	devices.{0} has an invalid format.
devices.desired_power_watts 超出允许范围。	devices.desired_power_watts is out of range.
频道数量超出允许范围。	Channel count is out of range.
频道项目必须是对象。	Channel entries must be objects.
频道项目缺少字段 {0}。	Channel entry is missing field {0}.
频道项目字段格式无效。	Channel entry has an invalid field format.
频道列表存在重复的类型、ID 和时隙。	Channel list has duplicate type, ID, and timeslot.
tx_channel_id 必须是频道 tuple key 字符串。	tx_channel_id must be a channel tuple key string.
频道列表为空时 tx_channel_id 必须为空。	tx_channel_id must be empty when the channel list is empty.
tx_channel_id 没有对应的频道项目。	tx_channel_id has no matching channel entry.
routing.blocked_source_ids 必须是数组。	routing.blocked_source_ids must be an array.
routing.blocked_source_ids 存在重复 ID。	routing.blocked_source_ids has duplicate IDs.
ui.bm_server_selection_id 字段格式无效。	ui.bm_server_selection_id has an invalid format.
ui.legacy_rx_policy 必须是对象或 null。	ui.legacy_rx_policy must be an object or null.
ui.language 只接受 zh-CN 或 en-US。	ui.language only accepts zh-CN or en-US.
config.json 不能保存凭据文件路径；请把凭据值存入 connection。	config.json cannot store credential file paths. Put credential values in connection.
config.json 超过 128 KiB；原文件已保留。	config.json exceeds 128 KiB; the original file was kept.
config.json JSON 无效；原文件已保留。	config.json has invalid JSON; the original file was kept.
旧 {0} 文件必须使用完整路径；原文件已保留。	The legacy {0} file must use a full path; the original file was kept.
旧 {0} 指针指向的文件不存在；原文件已保留。	The file referenced by the legacy {0} pointer does not exist; the original file was kept.
旧配置中的 {0} 文件无法读取；原文件已保留。	The {0} file in the legacy settings cannot be read; the original file was kept.
旧密码文件格式无效；原文件已保留。	Invalid legacy password file format; the original file was kept.
旧 BM API key 文件格式无效；原文件已保留。	Invalid legacy BM API key file format; the original file was kept.
旧 {0} 指针无法读取；原文件已保留。	The legacy {0} pointer cannot be read; the original file was kept.
旧 {0} 指针必须是单行完整文件路径；原文件已保留。	The legacy {0} pointer must be a single-line full file path; the original file was kept.
指定的旧配置目录不存在；没有改动配置文件。	The specified legacy settings directory does not exist; no settings file was changed.
迁移所需的旧连接配置读取模块缺失。	The module needed to read legacy connection settings for migration is missing.
旧连接配置无效；旧配置文件已保留，没有迁移。	Invalid legacy connection settings; the legacy files were kept and not migrated.
旧音量设置无效；旧配置文件已保留，没有迁移。	Invalid legacy audio settings; the legacy files were kept and not migrated.
旧电台控制偏好 JSON 无效；旧配置文件已保留，没有迁移。	Invalid legacy radio control preferences JSON; the legacy files were kept and not migrated.
旧电台控制偏好字段无效；旧配置文件已保留，没有迁移。	Invalid legacy radio control preference fields; the legacy files were kept and not migrated.
旧 BM 服务器偏好 JSON 无效；旧配置文件已保留，没有迁移。	Invalid legacy BM server preferences JSON; the legacy files were kept and not migrated.
旧 BM 服务器偏好字段无效；旧配置文件已保留，没有迁移。	Invalid legacy BM server preference fields; the legacy files were kept and not migrated.
旧 BM API 偏好 JSON 无效；旧配置文件已保留，没有迁移。	Invalid legacy BM API preferences JSON; the legacy files were kept and not migrated.
旧 BM API 偏好字段无效；旧配置文件已保留，没有迁移。	Invalid legacy BM API preference fields; the legacy files were kept and not migrated.
config.json 所在目录不存在；没有写入配置。	The config.json directory does not exist; settings were not written.
config.json 超过 128 KiB；没有写入配置。	config.json exceeds 128 KiB; settings were not written.
config.json 尚未初始化；没有写入语言设置。	config.json is not initialized; the language setting was not written.
config.json 超过 128 KiB；没有写入语言设置。	config.json exceeds 128 KiB; the language setting was not written.
便携配置目录不存在或无法访问；没有启动 WIREX Bridge。	The portable settings directory does not exist or is inaccessible; WIREX Bridge was not started.
默认 config.json 超过允许大小。	Default config.json exceeds the allowed size.
无法创建或验证 config.json；请检查便携目录的写入权限。没有启动 WIREX Bridge。	Cannot create or verify config.json. Check write permissions for the portable directory. WIREX Bridge was not started.
必须且只能提供一个 BM API key 来源。	Exactly one BM API key source must be provided.
BM API 文件必须使用完整路径。	The BM API file must use a full path.
找不到 BM API 文件。	BM API file not found.
无法读取已指定的 BM API 文件。	Cannot read the specified BM API file.
BM API key 格式无效；需要 BrandMeister API v2 token。	Invalid BM API key format; a BrandMeister API v2 token is required.
BM API 操作已取消。	BM API request cancelled.
BM 设备 ID 必须是 1 到 4294967295 的十进制整数。	BM device ID must be a decimal integer from 1 to 4294967295.
BM 设备信息只允许使用无后缀 GET 路径。	BM device info only allows a GET path without a suffix.
BM API 路径参数无效。	Invalid BM API path parameter.
BM API 只允许使用官方 HTTPS 服务地址。	BM API only allows the official HTTPS service address.
BM API 操作超过时限。	BM API request exceeded the time limit.
BM API fake transport 调用失败。	BM API fake transport call failed.
BM API transport 没有返回 HTTP 状态。	BM API transport returned no HTTP status.
BM API 返回内容超过大小上限。	BM API response exceeds the size limit.
BM API 请求失败；没有保存或显示 API token。	BM API request failed; the API token was not saved or shown.
BM API 返回 HTTP {0}。	BM API returned HTTP {0}.
BM API 静态组列表必须是 JSON 数组。	BM API static group list must be a JSON array.
BM API 返回的静态组列表不是有效 JSON。	The static group list returned by BM API is not valid JSON.
BM API 静态组项目缺少 TG 或时隙。	BM API static group entry is missing TG or timeslot.
BM API 静态组项目含有无效 TG 或时隙。	BM API static group entry has an invalid TG or timeslot.
BM API 静态组列表含有重复项目。	BM API static group list has duplicate entries.
RadioId 必须是 1 到 16777215 之间的 24 位 DMR ID。	RadioId must be a 24-bit DMR ID from 1 to 16777215.
CachePath 必须包含父目录。	CachePath must include a parent directory.
RadioID 查询已取消。	RadioID lookup cancelled.
RadioID 查询超过时间限制。	RadioID lookup exceeded the time limit.
RadioID 响应超过大小限制。	RadioID response exceeds the size limit.
RadioID 响应没有可读取的正文。	RadioID response has no readable body.
RadioID 响应超过时间限制。	RadioID response exceeded the time limit.
User-Agent 必须标识 WIREX Bridge 并包含联系地址。	User-Agent must identify WIREX Bridge and include a contact address.
RadioID 查询地址只接受官方 HTTPS 地址或本机 HTTP 测试夹具。	RadioID lookup only accepts the official HTTPS address or a local HTTP test fixture.
RadioID 查询没有返回响应。	RadioID lookup returned no response.
RadioID 响应缺失或超过大小限制。	RadioID response is missing or exceeds the size limit.
RadioID 查询返回 HTTP 状态 {0}。	RadioID lookup returned HTTP status {0}.
本机缓存保存失败	Failed to save local cache
RadioID 查询结果不唯一或 ID 不匹配（{0}）。	RadioID lookup result is not unique or the ID does not match ({0}).
自定义服务器	Custom server
自定义服务器地址不能为空。	Custom server address cannot be empty.
自定义服务器地址必须是不含空格且不超过 253 个字符的地址。	Custom server address must have no spaces and at most 253 characters.
自定义服务器 UDP 端口必须为 1 到 65535。	Custom server UDP port must be 1 to 65535.
所选服务器不在离线目录中；请使用自定义服务器或刷新应用目录。	The selected server is not in the offline directory. Use a custom server or refresh the app directory.
'@
foreach ($line in ($script:WirexUiEnglishTextTsv -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line) ) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -ne 2) { continue }
    $source = $parts[0].Replace('\n',"`n")
    if (-not $script:WirexUiEnglishText.Contains($source)) { $script:WirexUiEnglishText[$source] = $parts[1].Replace('\n',"`n") }
}
Remove-Variable -Name line,parts,source -ErrorAction SilentlyContinue

$script:WirexUiCjkPattern = [regex]'[　-〿㐀-鿿＀-￯]'
$script:WirexUiPlaceholderPattern = [regex]'\{(\d+)(?::[^}]*)?\}'
$script:WirexUiTemplates = @(
    foreach ($key in @($script:WirexUiEnglishText.Keys)) {
        $sourceKey = [string]$key
        if (-not $script:WirexUiPlaceholderPattern.IsMatch($sourceKey)) { continue }
        $pattern = New-Object System.Text.StringBuilder
        [void]$pattern.Append('^')
        $position = 0
        $slots = New-Object 'System.Collections.Generic.List[int]'
        foreach ($match in $script:WirexUiPlaceholderPattern.Matches($sourceKey)) {
            [void]$pattern.Append([regex]::Escape($sourceKey.Substring($position,$match.Index - $position)))
            [void]$pattern.Append('(.+?)')
            $slots.Add([int]$match.Groups[1].Value)
            $position = $match.Index + $match.Length
        }
        [void]$pattern.Append([regex]::Escape($sourceKey.Substring($position))).Append('$')
        [pscustomobject]@{
            Regex = [regex]::new($pattern.ToString(),[System.Text.RegularExpressions.RegexOptions]::Singleline)
            Slots = $slots.ToArray()
            English = [string]$script:WirexUiEnglishText[$key]
            LiteralLength = ($script:WirexUiPlaceholderPattern.Replace($sourceKey,'')).Length
        }
    }
) | Sort-Object -Property LiteralLength -Descending
Remove-Variable -Name key,sourceKey,pattern,position,slots,match -ErrorAction SilentlyContinue
$script:WirexUiTranslationCache = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
$script:WirexUiSourceCache = [System.Runtime.CompilerServices.ConditionalWeakTable[object,hashtable]]::new()

function Test-WirexUiTextHasCjk {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    return (-not [string]::IsNullOrEmpty($Text) -and $script:WirexUiCjkPattern.IsMatch($Text))
}

function ConvertFrom-WirexUiTemplate {
    param([Parameter(Mandatory=$true)][string]$Text,[Parameter(Mandatory=$true)][string]$Language,[int]$Depth)
    foreach ($template in $script:WirexUiTemplates) {
        $match = $template.Regex.Match($Text)
        if (-not $match.Success) { continue }
        $values = @{}
        for ($index = 0; $index -lt $template.Slots.Count; $index++) {
            $values[$template.Slots[$index]] = ConvertTo-WirexUiDisplayText -Text $match.Groups[$index + 1].Value -Language $Language -Depth ($Depth + 1)
        }
        $result = New-Object System.Text.StringBuilder
        $position = 0
        foreach ($slot in $script:WirexUiPlaceholderPattern.Matches($template.English)) {
            [void]$result.Append($template.English.Substring($position,$slot.Index - $position))
            $slotIndex = [int]$slot.Groups[1].Value
            if ($values.ContainsKey($slotIndex)) { [void]$result.Append([string]$values[$slotIndex]) } else { [void]$result.Append($slot.Value) }
            $position = $slot.Index + $slot.Length
        }
        [void]$result.Append($template.English.Substring($position))
        return $result.ToString()
    }
    return $null
}

function Get-WirexUiDisplayLanguage {
    param([AllowNull()][object]$Config)
    $language = 'zh-CN'
    if ($Config -and $Config.ui -and [string]$Config.ui.language -cin @('zh-CN','en-US')) { $language = [string]$Config.ui.language }
    return $language
}

function ConvertTo-WirexUiDisplayText {
    param([AllowEmptyString()][string]$Text,[ValidateSet('zh-CN','en-US')][string]$Language='zh-CN',[int]$Depth=0)
    if ($Language -ceq 'zh-CN' -or [string]::IsNullOrEmpty($Text)) { return $Text }
    if ($script:WirexUiEnglishText.Contains($Text)) { return [string]$script:WirexUiEnglishText[$Text] }
    if (-not $script:WirexUiCjkPattern.IsMatch($Text)) { return $Text }
    $cached = $null
    if ($script:WirexUiTranslationCache.TryGetValue($Text,[ref]$cached)) { return $cached }
    $translated = ConvertTo-WirexUiDisplayTextCore -Text $Text -Language $Language -Depth $Depth
    if ($script:WirexUiTranslationCache.Count -gt 4096) { $script:WirexUiTranslationCache.Clear() }
    $script:WirexUiTranslationCache[$Text] = $translated
    return $translated
}

function ConvertTo-WirexUiDisplayTextCore {
    param([Parameter(Mandatory=$true)][string]$Text,[Parameter(Mandatory=$true)][string]$Language,[int]$Depth=0)
    $trimmed = $Text.Trim()
    if ($trimmed.Length -gt 0 -and $trimmed.Length -lt $Text.Length) {
        $start = $Text.IndexOf($trimmed,[StringComparison]::Ordinal)
        return $Text.Substring(0,$start) + (ConvertTo-WirexUiDisplayText -Text $trimmed -Language $Language -Depth $Depth) +
            $Text.Substring($start + $trimmed.Length)
    }
    if ($Text -match '^(CAT 设置未全部完成；已读回确认的字段没有自动回滚。|CAT 设置已取消；已读回确认的字段没有自动回滚。|CAT 状态已读取；模式、频率、功率均与目标一致，没有发送设置帧。|CAT 模式、频率、功率已逐项读取；变化字段已读回目标值。)(?: (.+))?$') {
        $summary = ConvertTo-WirexUiDisplayText -Text $Matches[1] -Language $Language
        $detailText = [string]$Matches[2]
        if (-not $detailText) { return $summary }
        $translatedParts = @()
        foreach ($part in @($detailText -split '；')) {
            if ($part -match '^(模式|频率|功率)：(.+)$') {
                $label = ConvertTo-WirexUiDisplayText -Text $Matches[1] -Language $Language
                $value = [string]$Matches[2]
                $suffix = ''
                if ($value -match '^(.+?)(（.+）)$') { $value = $Matches[1]; $suffix = $Matches[2] }
                $valueText = ConvertTo-WirexUiDisplayText -Text $value -Language $Language
                $translatedParts += ($label + ': ' + $valueText + $suffix)
            } elseif ($part -match '^后续：(.+)$') {
                $translatedParts += ('Next: ' + [string]$Matches[1])
            } else {
                $translatedParts += ConvertTo-WirexUiDisplayText -Text $part -Language $Language
            }
        }
        return ($summary + ' ' + ($translatedParts -join '; '))
    }
    if ($Text -match '^设备 (.+)$') { return 'Device ' + $Matches[1] }
    if ($Text -ceq '正在检查已保存端点 · ') { return 'Checking saved endpoint · ' }
    if ($Text -ceq '已保存端点当前未发现 · ') { return 'Saved endpoint not found · ' }
    if ($Text -ceq '正在检查已保存 HRI 串口 · ') { return 'Checking saved HRI port · ' }
    if ($Text -ceq '已保存串口当前未发现为 HRI · ') { return 'Saved port not found as HRI · ' }
    if ($Text -match '^已读取 (\d+) 条 BM 静态组；设备状态 (\d+)(，添加已禁用)?。$') {
        $disabled = if ($Matches[3]) { '; adding is disabled' } else { '' }
        return ('Read {0} BM static groups; device status {1}{2}.' -f $Matches[1],$Matches[2],$disabled)
    }
    if ($Text -match '^已保存：(.+)$') { return 'Saved: ' + $Matches[1] }
    if ($Text -match '^增益 (.+)$') { return 'Gain ' + $Matches[1] }
    if ($Text -match '^播放 (.+) · 发送 (.+)$') { return 'Playback ' + $Matches[1] + ' · Transmit ' + $Matches[2] }
    if ($Text -match '^(\d+(?:\.\d+)?) ms · (\d+) 次$') { return $Matches[1] + ' ms · ' + $Matches[2] + ' samples' }
    if ($Text -match '^TG (\d+) TS([12])；静态组已读取。$') { return 'TG ' + $Matches[1] + ' TS' + $Matches[2] + '; static group read back.' }
    if ($Text -match '^TG (\d+) TS([12])；本机已发送上一条激活请求，BM 当前动态组状态未知。$') { return 'TG ' + $Matches[1] + ' TS' + $Matches[2] + '; a previous activation request was sent locally. BM dynamic group state is unknown.' }
    if ($Text -match '^来话 (\d+) · 私呼 · 来源 (.+)$') { return 'Call ' + $Matches[1] + ' · Private · from ' + $Matches[2] }
    if ($Text -match '^来话 (\d+) · 组呼 · 来源 (.+)$') { return 'Call ' + $Matches[1] + ' · Group · from ' + $Matches[2] }
    if ($Text -match '^TG (\d+) TS([12]) 等待当前通话结束超时；没有发送激活请求。$') { return ('TG {0} TS{1} timed out waiting for the current call to end; no activation request was sent.' -f $Matches[1],$Matches[2]) }
    if ($Text -match '^TG (\d+) TS([12]) 等待当前通话结束。$') { return ('TG {0} TS{1} is queued until the current call ends.' -f $Matches[1],$Matches[2]) }
    if ($Text -match '^TG (\d+) TS([12]) 激活请求已提交。$') { return ('TG {0} TS{1} activation request submitted.' -f $Matches[1],$Matches[2]) }
    if ($Text -match '^TG (\d+) TS([12]) 已由当前 BM 设备的静态组列表确认；无需激活。$') { return ('TG {0} TS{1} is confirmed in the current BM static group list; activation is not needed.' -f $Matches[1],$Matches[2]) }
    if ($Text -match '^已取消 TG (\d+) TS([12]) 的排队；没有发送激活请求。$') { return ('Cancelled the queued request for TG {0} TS{1}; no activation request was sent.' -f $Matches[1],$Matches[2]) }
    if ($Text -match '^应用中：(.+)；每项均单独读取并核对回读。$') {
        $step = switch -CaseSensitive ($Matches[1]) { '模式' {'mode'} '频率' {'frequency'} '功率' {'power'} default {$Matches[1]} }
        return ('Applying {0}; each setting is read and checked individually.' -f $step)
    }
    if ($Text -match '^CAT 设置已取消，没有发送写入：(.+)$') { return 'CAT settings were cancelled. No write was sent: ' + (ConvertTo-WirexUiDisplayText -Text $Matches[1] -Language $Language) }
    if ($Text -match '^HRI 已断开；没有执行 CAT 设置：(.+)$') { return 'HRI disconnected. CAT settings were not applied: ' + (ConvertTo-WirexUiDisplayText -Text $Matches[1] -Language $Language) }
    if ($Text -match '^当前条件不允许发送该设置：(.+)$') { return 'Current conditions do not allow this setting to be sent: ' + (ConvertTo-WirexUiDisplayText -Text $Matches[1] -Language $Language) }
    if ($Text -match '^后续：(.+)$') { return 'Next: ' + (ConvertTo-WirexUiDisplayText -Text $Matches[1] -Language $Language) }
    if ($Text -match '^动态组激活失败：(.+)$') { return 'Dynamic group activation failed: ' + $Matches[1] }
    if ($Text -match '^目标功率 (\d+) W 超出当前路径上限 (\d+) W；请重新选择有效功率。$') { return ('Target power {0} W exceeds the current path limit of {1} W. Choose a valid power level.' -f $Matches[1],$Matches[2]) }
    if ($Text -match '^(.+)；排队(?:已)?取消，没有发送激活请求。$') { return ('{0}; queue cancelled. No activation request was sent.' -f (ConvertTo-WirexUiDisplayText -Text $Matches[1] -Language $Language -Depth ($Depth + 1)).TrimEnd('.')) }
    if ($Text -match '^(.+)已保存。$') {
        $action = switch -CaseSensitive ($Matches[1]) {
            '加入频道' {'Channel added'} '取消监听' {'Listening removed'} '切换PTT目标' {'TX target changed'}
            '临时屏蔽' {'Channel muted'} '恢复收听' {'Channel unmuted'} '设置' {'Settings'} default {''}
        }
        if ($action) { return $action + ' saved.' }
    }
    if ($Text -match '^正在(.+)；等待核心确认当前频道设置。$') {
        $action = switch -CaseSensitive ($Matches[1]) {
            '加入频道' {'add channel'} '取消监听' {'remove listening'} '切换PTT目标' {'change the TX target'}
            '临时屏蔽' {'mute the channel'} '恢复收听' {'unmute the channel'} '更新频道' {'update channels'}
            '添加频道' {'add the channel'} '移除频道' {'remove the channel'} default {$Matches[1]}
        }
        return ('Applying {0}; waiting for the core to confirm channel settings.' -f $action)
    }
    if ($Depth -lt 6) {
        $templated = ConvertFrom-WirexUiTemplate -Text $Text -Language $Language -Depth $Depth
        if ($null -ne $templated) { return $templated }
        # Compound status lines join canonical sentences with Chinese punctuation or line breaks.
        foreach ($separator in @("`n",'；','。','：')) {
            $index = $Text.IndexOf($separator,[StringComparison]::Ordinal)
            if ($index -lt 0) { continue }
            $splitAt = $index + $(if ($separator -ceq '。') { 1 } else { 0 })
            $head = $Text.Substring(0,$splitAt)
            $tail = $Text.Substring($index + $separator.Length)
            if (-not $head -or -not $tail.Trim()) { continue }
            $headText = ConvertTo-WirexUiDisplayText -Text $head -Language $Language -Depth ($Depth + 1)
            $tailText = ConvertTo-WirexUiDisplayText -Text $tail.TrimStart() -Language $Language -Depth ($Depth + 1)
            $joiner = switch -CaseSensitive ($separator) { "`n" { "`n" } '；' { '; ' } '。' { ' ' } default { ': ' } }
            if ($separator -ceq '；') { $headText = $headText.TrimEnd('.') }
            return ($headText + $joiner + $tailText)
        }
    }
    return $Text
}

function Set-WirexUiLocalizedElementProperty {
    param([Parameter(Mandatory=$true)][object]$Element,
        [Parameter(Mandatory=$true)][ValidateSet('Text','Content','Title','ToolTip')][string]$Property,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourceText,
        [ValidateSet('zh-CN','en-US')][string]$Language='zh-CN',
        [switch]$UpdateSource)
    $sourceProperties = $null
    if (-not $script:WirexUiSourceCache.TryGetValue($Element,[ref]$sourceProperties)) {
        $sourceProperties = @{}
        try { $script:WirexUiSourceCache.Add($Element,$sourceProperties) }
        catch { [void]$script:WirexUiSourceCache.TryGetValue($Element,[ref]$sourceProperties) }
    }
    $displayKey = $Property + '#display'
    # Code that writes a new canonical text straight to the element (bypassing this function) must not be
    # overwritten by an older cached source on the next redraw; the last rendered text detects that case.
    $externallyChanged = ($sourceProperties.ContainsKey($displayKey) -and
        -not [string]::Equals([string]$Element.$Property,[string]$sourceProperties[$displayKey],[StringComparison]::Ordinal))
    if ($UpdateSource -or $externallyChanged -or -not $sourceProperties.ContainsKey($Property)) { $sourceProperties[$Property] = $SourceText }
    $displayText = ConvertTo-WirexUiDisplayText -Text ([string]$sourceProperties[$Property]) -Language $Language
    if (-not [string]::Equals([string]$Element.$Property,$displayText,[StringComparison]::Ordinal)) { $Element.$Property = $displayText }
    $sourceProperties[$displayKey] = $displayText
    return $displayText
}

function Update-WirexUiComboSelectionBox {
    param([AllowNull()][object]$Item)
    if ($Item -isnot [System.Windows.Controls.ComboBoxItem]) { return }
    $combo = [System.Windows.Controls.ItemsControl]::ItemsControlFromItemContainer($Item)
    if ($combo -isnot [System.Windows.Controls.ComboBox] -or $combo.IsEditable -or
        -not [object]::ReferenceEquals($combo.SelectedItem,$Item)) { return }
    # A non-editable ComboBox copies the selected Content into SelectionBoxItem only on selection change.
    # Refresh that copy without re-selecting, so no SelectionChanged handler runs during a language redraw.
    try {
        $method = [System.Windows.Controls.ComboBox].GetMethod('UpdateSelectionBoxItem',
            [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($method) { [void]$method.Invoke($combo,$null) }
    } catch { }
}

function Get-WirexUiLocalizationSourceTexts {
    return @($script:WirexUiEnglishText.Keys | ForEach-Object { [string]$_ })
}

function Set-WirexUiLocalizedWindow {
    param([Parameter(Mandatory=$true)][System.Windows.Window]$Window,
        [ValidateSet('zh-CN','en-US')][string]$Language='zh-CN')
    $skipSubtrees = @('LanguageToggleButton','TransientStatusText','BmValue','ConnectButton','SerialConnectButton',
        'BmStaticGroupSourceValue','IdentityLookupStatusValue','ChannelCardsPanel','CallHistoryList','BmStaticGroupsList',
        'BmStaticGroupPageText','BmRttValue','BmLossValue','ChannelPageText','CallHistoryPageText',
        'CatObservedPanel','CatObservedMainModeText','CatObservedFrequencyText','CatObservedPowerText','PlaybackGainValueText','TransmitGainValueText',
        'SerialBox','CatPortBox','WaveInEndpointBox','WaveOutEndpointBox')
    $pending = New-Object 'System.Collections.Generic.Stack[object]'
    $pending.Push($Window)
    while ($pending.Count -gt 0) {
        $node = $pending.Pop()
        if ($node -is [System.Windows.FrameworkElement] -and $skipSubtrees -ccontains [string]$node.Name) { continue }
        if ($node -is [System.Windows.Window]) {
            [void](Set-WirexUiLocalizedElementProperty -Element $node -Property Title -SourceText ([string]$node.Title) -Language $Language)
        }
        if ($node -is [System.Windows.Controls.TextBlock]) {
            $inlines = @($node.Inlines)
            $containsHyperlink = @($inlines | Where-Object { $_ -is [System.Windows.Documents.Hyperlink] }).Count -gt 0
            if (-not $containsHyperlink) {
                [void](Set-WirexUiLocalizedElementProperty -Element $node -Property Text -SourceText ([string]$node.Text) -Language $Language)
            } else {
                foreach ($inline in $inlines) {
                    if ($inline -is [System.Windows.Documents.Run]) {
                        [void](Set-WirexUiLocalizedElementProperty -Element $inline -Property Text -SourceText ([string]$inline.Text) -Language $Language)
                    } elseif ($inline -is [System.Windows.Documents.Hyperlink]) {
                        $linkInlines = @($inline.Inlines)
                        foreach ($linkInline in $linkInlines) {
                            if ($linkInline -is [System.Windows.Documents.Run]) {
                                [void](Set-WirexUiLocalizedElementProperty -Element $linkInline -Property Text -SourceText ([string]$linkInline.Text) -Language $Language)
                            }
                        }
                    }
                }
            }
        } elseif ($node -is [System.Windows.Controls.Button] -and $node.Content -is [string]) {
            [void](Set-WirexUiLocalizedElementProperty -Element $node -Property Content -SourceText ([string]$node.Content) -Language $Language)
        } elseif ($node -is [System.Windows.Controls.ComboBoxItem] -and $node.Content -is [string]) {
            $before = [string]$node.Content
            [void](Set-WirexUiLocalizedElementProperty -Element $node -Property Content -SourceText $before -Language $Language)
            if (-not [string]::Equals($before,[string]$node.Content,[StringComparison]::Ordinal)) { Update-WirexUiComboSelectionBox -Item $node }
        } elseif ($node -is [System.Windows.Controls.Label] -and $node.Content -is [string]) {
            [void](Set-WirexUiLocalizedElementProperty -Element $node -Property Content -SourceText ([string]$node.Content) -Language $Language)
        }
        if ($node -is [System.Windows.FrameworkElement] -and $node.ToolTip -is [string]) {
            [void](Set-WirexUiLocalizedElementProperty -Element $node -Property ToolTip -SourceText ([string]$node.ToolTip) -Language $Language)
        }
        if ($node -is [System.Windows.DependencyObject]) {
            $children = @([System.Windows.LogicalTreeHelper]::GetChildren($node))
            foreach ($child in $children) {
                if ($child -is [System.Windows.DependencyObject] -or $child -is [System.Windows.Documents.Run]) { $pending.Push($child) }
            }
        }
    }
}

Export-ModuleMember -Function Get-WirexUiDisplayLanguage, ConvertTo-WirexUiDisplayText, Set-WirexUiLocalizedElementProperty, Set-WirexUiLocalizedWindow,
    Update-WirexUiComboSelectionBox, Get-WirexUiLocalizationSourceTexts, Test-WirexUiTextHasCjk
