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
$script:WirexUiSourceCache = [System.Runtime.CompilerServices.ConditionalWeakTable[object,hashtable]]::new()

function Get-WirexUiDisplayLanguage {
    param([AllowNull()][object]$Config)
    $language = 'zh-CN'
    if ($Config -and $Config.ui -and [string]$Config.ui.language -cin @('zh-CN','en-US')) { $language = [string]$Config.ui.language }
    return $language
}

function ConvertTo-WirexUiDisplayText {
    param([AllowEmptyString()][string]$Text,[ValidateSet('zh-CN','en-US')][string]$Language='zh-CN')
    if ($Language -ceq 'zh-CN' -or [string]::IsNullOrEmpty($Text)) { return $Text }
    if ($script:WirexUiEnglishText.Contains($Text)) { return [string]$script:WirexUiEnglishText[$Text] }
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
    if ($Text -match '^(.+)；排队(?:已)?取消，没有发送激活请求。$') { return ('{0}; queue cancelled. No activation request was sent.' -f $Matches[1]) }
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
    if ($UpdateSource -or -not $sourceProperties.ContainsKey($Property)) { $sourceProperties[$Property] = $SourceText }
    $displayText = ConvertTo-WirexUiDisplayText -Text ([string]$sourceProperties[$Property]) -Language $Language
    $Element.$Property = $displayText
    return $displayText
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
            [void](Set-WirexUiLocalizedElementProperty -Element $node -Property Content -SourceText ([string]$node.Content) -Language $Language)
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

Export-ModuleMember -Function Get-WirexUiDisplayLanguage, ConvertTo-WirexUiDisplayText, Set-WirexUiLocalizedElementProperty, Set-WirexUiLocalizedWindow
