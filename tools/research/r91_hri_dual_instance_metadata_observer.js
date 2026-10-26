'use strict';

// R91：限时读取 HRI_UART.dll DAT_10191d38 两个实例槽的数值元数据。
// 只读并逐字节扫描 header 到 NUL（最多 512 字节），不保留或输出正文。
// 不挂钩函数、不调用目标代码或导出函数、不写内存。
// 使用前先对实际安装目录 C:\\Program Files (x86)\\YAESUMUSEN\\WIRES-X 下三个目标文件运行 Get-FileHash -Algorithm SHA256，逐一核对下列值；本脚本只核对运行时路径，不核验映像内存哈希。
// WIRES_X.EXE: 8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671
// HRI_UART.dll: 56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed
// RigDataIf.dll: 94d1217feb047288329e79e0d5de2167c79450f1945119b2ed6c6376b02a7410
const TARGET_MAIN_PATH = 'c:/program files (x86)/yaesumusen/wires-x/wires-x.exe';
const TARGET_HRI_PATH = 'c:/program files (x86)/yaesumusen/wires-x/hri-uart.dll';
const TARGET_RIGDATAIF_PATH = 'c:/program files (x86)/yaesumusen/wires-x/rigdataif.dll';
const EXPECTED_MAIN_SHA256 = '8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671';
const EXPECTED_HRI_SHA256 = '56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed';
const EXPECTED_RIGDATAIF_SHA256 = '94d1217feb047288329e79e0d5de2167c79450f1945119b2ed6c6376b02a7410';
const GLOBAL_TABLE_RVA = 0x191d38; // HRI_UART.dll DAT_10191d38, x86 image base 0x10000000
const INSTANCE_TABLE_SLOT_COUNT = 2;
const RIGDATAIF_QUEUE_HEAD_RVA = 0x16830c; // fixed VA 0x1016830c
const RIGDATAIF_QUEUE_COUNT_RVA = 0x16831c; // fixed VA 0x1016831c
const RIGDATAIF_ANA_QUEUE_HEAD_RVA = 0x168324; // fixed VA 0x10168324
const RIGDATAIF_ANA_QUEUE_COUNT_RVA = 0x168334; // fixed VA 0x10168334
const POLL_INTERVAL_MS = 100;
const MAX_OBSERVE_MS = 10000;
const MAX_CHANGE_EVENTS = 16;
const HEADER_OFFSET = 0x1420;
const HEADER_SCAN_CAP = 512;
const CALLBACK_TABLE_OFFSET = 0x1d8ec;
const OBJECT_DWORD_OFFSETS = [0x44, 0x50, 0x58, 0x1d4, 0x1dc, 0x28f8, 0x28e4, 0x28e8];
const CHILD_DWORD_OFFSETS = [0x2c4, 0x2bc];

let startedAt = Date.now();
let stopped = false;
let pollTimer = null;
let timeoutTimer = null;
let sampleCount = 0;
let changedSampleCount = 0;
let emittedChangeEvents = 0;
let omittedChangeEvents = 0;
let firstSnapshot = null;
let lastSnapshot = null;
let lastSnapshotKey = null;
let targetRejectEmitted = false;

function emit(type, fields = {}) {
  if (stopped && type !== 'observer_stopped') return;
  try { send(Object.assign({ type, host_time_utc: new Date().toISOString() }, fields)); } catch (_) {}
}
function ptrText(pointer) { try { return pointer == null ? null : pointer.toString(); } catch (_) { return null; } }
function ptrKey(pointer) { const value = ptrText(pointer); return value === null ? null : value.toLowerCase(); }
function asU32(pointer) { try { return pointer.toUInt32() >>> 0; } catch (_) { return null; } }
function isNullPointer(pointer) { if (pointer == null) return true; try { return pointer.isNull(); } catch (_) { return false; } }
function normalizePath(value) { try { return String(value || '').replace(/\\/g, '/').toLowerCase(); } catch (_) { return ''; } }

function readableSpan(pointer, length) {
  if (isNullPointer(pointer)) return { valid: false, reason: 'null_pointer' };
  if (!Number.isInteger(length) || length <= 0) return { valid: false, reason: 'invalid_length' };
  if (typeof Process.findRangeByAddress !== 'function') return { valid: false, reason: 'range_api_unavailable' };
  try {
    const range = Process.findRangeByAddress(pointer);
    if (!range) return { valid: false, reason: 'unmapped_address' };
    const address = asU32(pointer), base = asU32(range.base), size = Number(range.size);
    if (address === null || base === null || !Number.isSafeInteger(size) || size < 0) return { valid: false, reason: 'range_metadata_unavailable' };
    if (String(range.protection || '').indexOf('r') < 0) return { valid: false, reason: 'range_not_readable' };
    const end = address + length, rangeEnd = base + size;
    if (end > 0x100000000 || rangeEnd > 0x100000000 || address < base || end > rangeEnd) return { valid: false, reason: 'span_outside_readable_range' };
    return { valid: true, range, address, rangeEnd };
  } catch (_) { return { valid: false, reason: 'range_check_failed' }; }
}

function fieldAddress(pointer, offset) {
  try { return { address: pointer.add(offset), reason: null }; }
  catch (_) { return { address: null, reason: 'field_address_failed' }; }
}
function readU32At(pointer, offset) {
  if (isNullPointer(pointer)) return { value: null, read_reason: 'null_base_pointer' };
  const located = fieldAddress(pointer, offset);
  if (located.reason) return { value: null, read_reason: located.reason };
  const check = readableSpan(located.address, 4);
  if (!check.valid) return { value: null, read_reason: check.reason };
  try { return { value: located.address.readU32() >>> 0, read_reason: null }; }
  catch (_) { return { value: null, read_reason: 'dword_read_failed' }; }
}
function readU8At(pointer, offset) {
  if (isNullPointer(pointer)) return { value: null, read_reason: 'null_base_pointer' };
  const located = fieldAddress(pointer, offset);
  if (located.reason) return { value: null, read_reason: located.reason };
  const check = readableSpan(located.address, 1);
  if (!check.valid) return { value: null, read_reason: check.reason };
  try { return { value: located.address.readU8() & 0xff, read_reason: null }; }
  catch (_) { return { value: null, read_reason: 'byte_read_failed' }; }
}
function readPointerAt(pointer, offset) {
  if (isNullPointer(pointer)) return { value: null, address: null, read_reason: 'null_base_pointer' };
  const located = fieldAddress(pointer, offset);
  if (located.reason) return { value: null, address: null, read_reason: located.reason };
  const check = readableSpan(located.address, 4);
  if (!check.valid) return { value: null, address: null, read_reason: check.reason };
  try {
    const value = located.address.readPointer();
    return { value, address: ptrText(value), read_reason: null };
  } catch (_) { return { value: null, address: null, read_reason: 'pointer_read_failed' }; }
}

function targetModules() {
  let main;
  try { main = Process.mainModule; }
  catch (_) { return { reason: 'main_module_query_failed' }; }
  if (!main) return { waiting: true, reason: 'main_module_unavailable' };
  const mainPath = normalizePath(main.path || main.name);
  if (mainPath !== TARGET_MAIN_PATH) return { reason: 'main_module_path_mismatch', main_path: String(main.path || main.name || '') };
  if (Process.pointerSize !== 4) return { reason: 'unexpected_pointer_size', pointer_size: Process.pointerSize };
  let modules;
  try {
    if (typeof Process.enumerateModules !== 'function') return { reason: 'module_enumeration_unavailable' };
    modules = Process.enumerateModules();
  } catch (_) { return { reason: 'module_enumeration_failed' }; }
  const matches = modules.filter((module) => normalizePath(module.path || module.name) === TARGET_HRI_PATH);
  if (matches.length === 0) return { waiting: true, reason: 'target_hri_module_not_loaded' };
  if (matches.length !== 1) return { reason: 'ambiguous_target_hri_module', match_count: matches.length };
  const hri = matches[0], base = asU32(hri.base), size = Number(hri.size);
  if (base === null || !Number.isSafeInteger(size) || size <= GLOBAL_TABLE_RVA + INSTANCE_TABLE_SLOT_COUNT * 4) return { reason: 'invalid_target_hri_module_range' };
  const rigMatches = modules.filter((module) => normalizePath(module.path || module.name) === TARGET_RIGDATAIF_PATH);
  let rigdataif = null, rigdataifReason = null;
  if (rigMatches.length === 0) rigdataifReason = 'target_rigdataif_module_not_loaded';
  else if (rigMatches.length !== 1) rigdataifReason = 'ambiguous_target_rigdataif_module';
  else {
    const candidate = rigMatches[0], rigBase = asU32(candidate.base), rigSize = Number(candidate.size);
    if (rigBase === null || !Number.isSafeInteger(rigSize) || rigSize <= RIGDATAIF_ANA_QUEUE_COUNT_RVA + 4) rigdataifReason = 'invalid_target_rigdataif_module_range';
    else rigdataif = candidate;
  }
  return { main, hri, rigdataif, rigdataifReason, reason: null };
}

function inspectOwner(pointer) {
  if (isNullPointer(pointer)) return { address: ptrText(pointer), owner: null, rva: null, range_protection: null, read_reason: 'null_function_pointer' };
  const rangeCheck = readableSpan(pointer, 1);
  let owner = null, rva = null;
  try {
    if (typeof Process.findModuleByAddress === 'function') {
      const module = Process.findModuleByAddress(pointer);
      if (module) {
        const base = asU32(module.base), address = asU32(pointer), size = Number(module.size);
        const inside = base !== null && address !== null && Number.isSafeInteger(size) && address >= base && address < base + size;
        owner = { name: String(module.name || ''), path: String(module.path || ''), in_module_span: inside };
        rva = inside ? '0x' + (address - base).toString(16) : null;
      }
    }
  } catch (_) {}
  const modulePath = owner ? normalizePath(owner.path) : '';
  const knownDirectRva = rva === '0x9f20' || rva === '0x9fe0';
  return {
    address: ptrText(pointer),
    rva,
    owner,
    range_protection: rangeCheck.valid ? String(rangeCheck.range.protection || '') : null,
    read_reason: rangeCheck.valid ? null : rangeCheck.reason,
    matches_static_direct_slot_rva: modulePath === TARGET_HRI_PATH && knownDirectRva
  };
}

function inspectCStringLength(basePointer, offset) {
  const located = fieldAddress(basePointer, offset);
  if (located.reason) return { nul_terminated_length: null, bytes_scanned: 0, truncated: null, read_reason: located.reason };
  const initial = readableSpan(located.address, 1);
  if (!initial.valid) return { nul_terminated_length: null, bytes_scanned: 0, truncated: null, read_reason: initial.reason };
  const address = asU32(located.address), available = initial.rangeEnd - address;
  if (!Number.isSafeInteger(available) || available <= 0) return { nul_terminated_length: null, bytes_scanned: 0, truncated: null, read_reason: 'invalid_readable_range_size' };
  const scanLength = Math.min(HEADER_SCAN_CAP, available);
  let scanned = 0;
  for (; scanned < scanLength; scanned += 1) {
    const byteAddress = located.address.add(scanned);
    const span = readableSpan(byteAddress, 1);
    if (!span.valid) return { nul_terminated_length: null, bytes_scanned: scanned, truncated: null, read_reason: span.reason };
    try {
      if ((byteAddress.readU8() & 0xff) === 0) return { nul_terminated_length: scanned, bytes_scanned: scanned + 1, truncated: false, read_reason: null };
    } catch (_) { return { nul_terminated_length: null, bytes_scanned: scanned, truncated: null, read_reason: 'bounded_header_byte_read_failed' }; }
  }
  return { nul_terminated_length: null, bytes_scanned: scanned, truncated: true, read_reason: null };
}

function inspectRigDataIfQueue(module, unavailableReason) {
  const base = {
    expected_module_path: TARGET_RIGDATAIF_PATH,
    expected_sha256: EXPECTED_RIGDATAIF_SHA256,
    runtime_module_hash_verified: false,
    module_path: module ? String(module.path || module.name || '') : null
  };
  if (!module) return Object.assign(base, { head_is_null: null, count32: null, head_read_reason: unavailableReason || 'target_rigdataif_module_unavailable', count_read_reason: unavailableReason || 'target_rigdataif_module_unavailable' });
  const head = readPointerAt(module.base, RIGDATAIF_QUEUE_HEAD_RVA);
  const count = readU32At(module.base, RIGDATAIF_QUEUE_COUNT_RVA);
  return Object.assign(base, {
    head_rva: '0x' + RIGDATAIF_QUEUE_HEAD_RVA.toString(16),
    head_is_null: head.read_reason ? null : isNullPointer(head.value),
    head_read_reason: head.read_reason,
    count_rva: '0x' + RIGDATAIF_QUEUE_COUNT_RVA.toString(16),
    count32: count.value,
    count_read_reason: count.read_reason
  });
}

function inspectRigDataIfAnaQueue(module, unavailableReason) {
  const base = {
    expected_module_path: TARGET_RIGDATAIF_PATH,
    expected_sha256: EXPECTED_RIGDATAIF_SHA256,
    runtime_module_hash_verified: false,
    module_path: module ? String(module.path || module.name || '') : null
  };
  if (!module) return Object.assign(base, { head_is_null: null, count32: null, head_read_reason: unavailableReason || 'target_rigdataif_module_unavailable', count_read_reason: unavailableReason || 'target_rigdataif_module_unavailable' });
  const head = readPointerAt(module.base, RIGDATAIF_ANA_QUEUE_HEAD_RVA);
  const count = readU32At(module.base, RIGDATAIF_ANA_QUEUE_COUNT_RVA);
  return Object.assign(base, {
    head_rva: '0x' + RIGDATAIF_ANA_QUEUE_HEAD_RVA.toString(16),
    head_is_null: head.read_reason ? null : isNullPointer(head.value),
    head_read_reason: head.read_reason,
    count_rva: '0x' + RIGDATAIF_ANA_QUEUE_COUNT_RVA.toString(16),
    count32: count.value,
    count_read_reason: count.read_reason
  });
}

function inspectSelectedQueueCallbacks(objectPointer, selectorValue) {
  const table = readPointerAt(objectPointer, CALLBACK_TABLE_OFFSET);
  const result = {
    table_pointer: table.address,
    table_read_reason: table.read_reason,
    static_queue_candidate: selectorValue === null ? null : selectorValue === 2 ? 'HRI' : 'ANA',
    get_callback_offset: null,
    count_callback_offset: null,
    get_callback: null,
    count_callback: null
  };
  if (selectorValue === null || table.read_reason || !table.value || isNullPointer(table.value)) return result;
  const getOffset = selectorValue === 2 ? 0x44 : 0x64;
  const countOffset = selectorValue === 2 ? 0x48 : 0x68;
  result.get_callback_offset = '0x' + getOffset.toString(16);
  result.count_callback_offset = '0x' + countOffset.toString(16);
  const get = readPointerAt(table.value, getOffset);
  const count = readPointerAt(table.value, countOffset);
  result.get_callback = get.read_reason || !get.value || isNullPointer(get.value)
    ? { address: get.address, rva: null, owner: null, read_reason: get.read_reason || 'null_callback' }
    : Object.assign({ read_reason: null }, inspectOwner(get.value));
  result.count_callback = count.read_reason || !count.value || isNullPointer(count.value)
    ? { address: count.address, rva: null, owner: null, read_reason: count.read_reason || 'null_callback' }
    : Object.assign({ read_reason: null }, inspectOwner(count.value));
  return result;
}

function inspectInstance(tableAddress, tableSlot, tableCheck) {
  if (!tableCheck.valid) return { instance_table_slot: tableSlot, object_address: null, object_read_reason: tableCheck.reason };
  const objectPointer = readPointerAt(tableAddress, tableSlot * 4);
  const instance = { instance_table_slot: tableSlot, object_address: objectPointer.address };
  if (objectPointer.read_reason) return Object.assign(instance, { object_read_reason: objectPointer.read_reason });
  if (isNullPointer(objectPointer.value)) return Object.assign(instance, { object_read_reason: 'instance_slot_is_null' });
  const objectCheck = readableSpan(objectPointer.value, 1);
  if (!objectCheck.valid) return Object.assign(instance, { object_read_reason: objectCheck.reason });

  const objectFields = {};
  for (const offset of OBJECT_DWORD_OFFSETS) objectFields['0x' + offset.toString(16)] = readU32At(objectPointer.value, offset);
  objectFields['0x248c'] = readU8At(objectPointer.value, 0x248c);

  const childPointer = readPointerAt(objectPointer.value, 0x2b8);
  const childFields = {};
  let childVtable = { value: null, address: null, read_reason: childPointer.read_reason || 'null_child_pointer' };
  if (childPointer.value && !isNullPointer(childPointer.value)) {
    childVtable = readPointerAt(childPointer.value, 0);
    for (const offset of CHILD_DWORD_OFFSETS) childFields['0x' + offset.toString(16)] = readU32At(childPointer.value, offset);
  } else {
    for (const offset of CHILD_DWORD_OFFSETS) childFields['0x' + offset.toString(16)] = { value: null, read_reason: childPointer.read_reason || 'null_child_pointer' };
  }

  const recordContext = readPointerAt(objectPointer.value, 0x2b4);
  const recordContextRaw10 = recordContext.value && !isNullPointer(recordContext.value)
    ? readU32At(recordContext.value, 0x10)
    : { value: null, read_reason: recordContext.read_reason || 'null_record_context' };
  const factoryObject = recordContext.value && !isNullPointer(recordContext.value) ? readPointerAt(recordContext.value, 0x14) : { value: null, address: null, read_reason: recordContext.read_reason || 'null_record_context' };
  const vtable = factoryObject.value && !isNullPointer(factoryObject.value) ? readPointerAt(factoryObject.value, 0) : { value: null, address: null, read_reason: factoryObject.read_reason || 'null_factory_object' };
  const methods = [];
  if (vtable.value && !isNullPointer(vtable.value)) {
    for (let index = 0; index < 2; index += 1) {
      const method = readPointerAt(vtable.value, index * 4);
      methods.push(method.value && !isNullPointer(method.value) ? Object.assign({ slot_index: index }, inspectOwner(method.value)) : { slot_index: index, address: null, rva: null, owner: null, read_reason: method.read_reason || 'null_method_pointer' });
    }
  } else {
    methods.push({ slot_index: 0, address: null, rva: null, owner: null, read_reason: vtable.read_reason || 'null_vtable' });
    methods.push({ slot_index: 1, address: null, rva: null, owner: null, read_reason: vtable.read_reason || 'null_vtable' });
  }

  const queueSelectorValue = objectFields['0x28f8'].value;
  const selectorBranch = queueSelectorValue === null ? { raw_value: null, selected_get_offset: null, read_reason: objectFields['0x28f8'].read_reason } : {
    raw_value: queueSelectorValue,
    selected_get_offset: queueSelectorValue === 2 ? '0x44' : '0x64',
    selected_count_offset: queueSelectorValue === 2 ? '0x48' : '0x68',
    static_queue_candidate: queueSelectorValue === 2 ? 'HRI' : 'ANA',
    mapping_basis: 'R64 static candidate: object+0x28f8==2 selects +0x44/+0x48; other values select +0x64/+0x68. This is not a decoded NodeMode or slot meaning.'
  };
  const selectedCallbacks = inspectSelectedQueueCallbacks(objectPointer.value, queueSelectorValue);
  return Object.assign(instance, {
    object_read_reason: null,
    object_fields_raw_u32_and_u8: objectFields,
    trcvtype_0x50_raw_u32: objectFields['0x50'],
    ope_mode_0x58_raw_u32: objectFields['0x58'],
    hri_0x1d4_raw_u32: objectFields['0x1d4'],
    hri_0x1dc_raw_u32: objectFields['0x1dc'],
    queue_selector_28f8_candidate: selectorBranch,
    selected_queue_callback_metadata: selectedCallbacks,
    child_pointer: { address: childPointer.address, read_reason: childPointer.read_reason },
    child_vtable: childVtable.read_reason || !childVtable.value || isNullPointer(childVtable.value)
      ? { address: childVtable.address, rva: null, owner: null, read_reason: childVtable.read_reason || 'null_child_vtable' }
      : Object.assign({ read_reason: null }, inspectOwner(childVtable.value)),
    child_fields_u32: childFields,
    record_context_pointer: { address: recordContext.address, read_reason: recordContext.read_reason },
    record_context_plus_0x10_raw_u32: recordContextRaw10,
    factory_object_pointer: { address: factoryObject.address, read_reason: factoryObject.read_reason },
    vtable_pointer: { address: vtable.address, read_reason: vtable.read_reason },
    first_two_factory_methods: methods,
    header_length_only: inspectCStringLength(objectPointer.value, HEADER_OFFSET)
  });
}

function makeSnapshot(module, rigdataifModule, rigdataifReason, sampleNumber) {
  const tableAddress = module.base.add(GLOBAL_TABLE_RVA);
  const tableCheck = readableSpan(tableAddress, INSTANCE_TABLE_SLOT_COUNT * 4);
  const instances = [];
  for (let slot = 0; slot < INSTANCE_TABLE_SLOT_COUNT; slot += 1) {
    const instance = inspectInstance(tableAddress, slot, tableCheck);
    const selector = instance.object_fields_raw_u32_and_u8 && instance.object_fields_raw_u32_and_u8['0x28f8'];
    let countSource = null;
    if (selector && selector.value !== null) {
      countSource = selector.value === 2
        ? inspectRigDataIfQueue(rigdataifModule, rigdataifReason)
        : inspectRigDataIfAnaQueue(rigdataifModule, rigdataifReason);
    }
    instance.selected_queue_count_metadata = countSource === null
      ? { static_queue_candidate: null, count32: null, read_reason: selector ? selector.read_reason : instance.object_read_reason }
      : { static_queue_candidate: selector.value === 2 ? 'HRI' : 'ANA', count32: countSource.count32, read_reason: countSource.count_read_reason };
    instances.push(instance);
  }
  return {
    sample_number: sampleNumber,
    hri_module_path: String(module.path || module.name || ''),
    hri_module_base: ptrText(module.base),
    expected_main_sha256: EXPECTED_MAIN_SHA256,
    expected_hri_sha256: EXPECTED_HRI_SHA256,
    runtime_module_hash_verified: false,
    global_table_rva: '0x' + GLOBAL_TABLE_RVA.toString(16),
    global_table_address: ptrText(tableAddress),
    instance_table_slot_count: INSTANCE_TABLE_SLOT_COUNT,
    instance_table_read_reason: tableCheck.valid ? null : tableCheck.reason,
    rigdataif_queue_metadata: inspectRigDataIfQueue(rigdataifModule, rigdataifReason),
    rigdataif_ana_queue_metadata: inspectRigDataIfAnaQueue(rigdataifModule, rigdataifReason),
    instances
  };
}

function stopObserver(reason) {
  if (stopped) return;
  try { if (pollTimer !== null) clearTimeout(pollTimer); } catch (_) {}
  try { if (timeoutTimer !== null) clearTimeout(timeoutTimer); } catch (_) {}
  if (firstSnapshot !== null) {
    emit('observer_summary', {
      reason,
      sample_count: sampleCount,
      changed_sample_count: changedSampleCount,
      emitted_change_events: emittedChangeEvents,
      omitted_change_events: omittedChangeEvents,
      first_snapshot: firstSnapshot,
      last_snapshot: lastSnapshot,
      observation_only: true
    });
  }
  stopped = true;
  emit('observer_stopped', { reason, poll_interval_ms: POLL_INTERVAL_MS, max_observe_ms: MAX_OBSERVE_MS, sample_count: sampleCount });
}

function poll() {
  if (stopped) return;
  const target = targetModules();
  if (target.reason && !target.waiting) {
    if (!targetRejectEmitted) {
      targetRejectEmitted = true;
      emit('target_rejected', { reason: target.reason, main_module_path: target.main_path || null, pointer_size: target.pointer_size || Process.pointerSize, module_match_count: target.match_count || null });
    }
    stopObserver(target.reason);
    return;
  }
  if (target.waiting) {
    if (Date.now() - startedAt >= MAX_OBSERVE_MS) { stopObserver('time_limit_waiting_for_target_module'); return; }
    pollTimer = setTimeout(poll, POLL_INTERVAL_MS);
    return;
  }
  sampleCount += 1;
  const snapshot = makeSnapshot(target.hri, target.rigdataif, target.rigdataifReason, sampleCount);
  const comparableSnapshot = Object.assign({}, snapshot);
  delete comparableSnapshot.sample_number;
  const key = JSON.stringify(comparableSnapshot);
  if (firstSnapshot === null) {
    firstSnapshot = snapshot;
    emit('first_dual_instance_metadata_snapshot', { sample_number: sampleCount, snapshot });
  } else if (key !== lastSnapshotKey) {
    changedSampleCount += 1;
    if (emittedChangeEvents < MAX_CHANGE_EVENTS) {
      emittedChangeEvents += 1;
      emit('dual_instance_metadata_changed', { sample_number: sampleCount, changed_sample_count: changedSampleCount, snapshot });
    } else omittedChangeEvents += 1;
  }
  lastSnapshot = snapshot;
  lastSnapshotKey = key;
  if (Date.now() - startedAt >= MAX_OBSERVE_MS) { stopObserver('time_limit_10_seconds'); return; }
  pollTimer = setTimeout(poll, POLL_INTERVAL_MS);
}

emit('observer_started', {
  expected_main_module_path: TARGET_MAIN_PATH,
  expected_hri_module_path: TARGET_HRI_PATH,
  expected_rigdataif_module_path: TARGET_RIGDATAIF_PATH,
  expected_main_sha256: EXPECTED_MAIN_SHA256,
  expected_hri_sha256: EXPECTED_HRI_SHA256,
  expected_rigdataif_sha256: EXPECTED_RIGDATAIF_SHA256,
  runtime_module_hash_verified: false,
  disk_hash_preflight_required_before_observation: true,
  global_table_rva: '0x' + GLOBAL_TABLE_RVA.toString(16),
  instance_table_slot_count: INSTANCE_TABLE_SLOT_COUNT,
  poll_interval_ms: POLL_INTERVAL_MS,
  max_observe_ms: MAX_OBSERVE_MS,
  max_change_events: MAX_CHANGE_EVENTS,
  header_scan_cap_bytes: HEADER_SCAN_CAP,
  rigdataif_queue_head_rva: '0x' + RIGDATAIF_QUEUE_HEAD_RVA.toString(16),
  rigdataif_queue_count_rva: '0x' + RIGDATAIF_QUEUE_COUNT_RVA.toString(16),
  rigdataif_ana_queue_head_rva: '0x' + RIGDATAIF_ANA_QUEUE_HEAD_RVA.toString(16),
  rigdataif_ana_queue_count_rva: '0x' + RIGDATAIF_ANA_QUEUE_COUNT_RVA.toString(16),
  policy: 'bounded_read_only_no_hooks_no_export_calls_no_memory_writes_no_header_body_output',
  purpose: 'observe_two_instance_table_entries_configuration_raw_values_child_factory_and_static_queue_candidates'
});
timeoutTimer = setTimeout(() => stopObserver('time_limit_10_seconds'), MAX_OBSERVE_MS);
poll();
