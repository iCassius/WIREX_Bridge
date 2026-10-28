'use strict';

// R110：面向已运行的 WIRES-X 2.010 x86 进程的限时只读元数据观察器。
// 脚本不启动厂商程序、不调用目标导出、不主动修改业务数据或 API 参数/返回值，
// 不打开设备，也不读取音频样本。Frida 安装 hook 时可能建立跳板或改写自身所需的
// 代码位置；本脚本不主动写入业务内存。
//
// Before attaching, an operator must verify the on-disk SHA-256 values in the
// R110 report. This script checks exact module paths and code-entry bytes; it
// cannot authenticate bytes in an already loaded image.

const OBSERVER_NAME = 'r110_official_rx_path_observer';
const TARGET_MAIN_PATH = 'c:/program files (x86)/yaesumusen/wires-x/wires-x.exe';
const TARGET_HRI_PATH = 'c:/program files (x86)/yaesumusen/wires-x/hri-uart.dll';
const MAIN_SHA256 = '8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671';
const HRI_SHA256 = '56e0050ef6afc53ba9c68ea51c7a13ec263f580b609f81146b897b58ae4effed';
const IMAGE_BASE = 0x00400000;
const MAX_CAPTURE_MS = 25000;
const MAX_EVENTS = 1024;
const MAX_SERIAL_RECORDS = 256;
const MAX_TRACKED_HANDLES = 8;
const MAX_IO_BYTES = 1024 * 1024;
const WAVEHDR_X86_SIZE = 0x20;
const SOH = 0x01;
const EOT = 0x04;
const OFFICIAL_WRITER_CALLSITE_VA = 0x0040F7F4;
const OFFICIAL_WRITER_RETURN_VA = 0x0040F7FA;
const OFFICIAL_WRITER_CALLSITE_SIGNATURE = 'ff156c967000';
const OFFICIAL_WRITER_CALLSITE_RVA = vaToRva(OFFICIAL_WRITER_CALLSITE_VA);
const OFFICIAL_WRITER_RETURN_RVA = vaToRva(OFFICIAL_WRITER_RETURN_VA);

function vaToRva(va, imageBase = IMAGE_BASE) {
  if (!Number.isInteger(va) || !Number.isInteger(imageBase) || va < imageBase) return null;
  return va - imageBase;
}

// Exact initial bytes came from the hash-pinned EXE's Ghidra listing.
const EXE_TARGETS = [
  { name: 'StartRcvVoice', va: 0x004E6D30, signature: '558bec565768600600006a00', returnCode: true },
  { name: 'ConnectCntl', va: 0x004D6DF0, signature: '558bec81ecd0000000', rowStackArgument: 1 },
  { name: 'PttWrapper', va: 0x0040DDB0, signature: '558bec5356576a288bf9', gateSnapshot: true },
];
for (const target of EXE_TARGETS) target.rva = vaToRva(target.va);

// These are static VAs from WIRES_X.EXE, translated using PE ImageBase 0x400000.
const MODE_GLOBALS = [
  { name: 'b8', va: 0x02F1C7B8, rva: vaToRva(0x02F1C7B8) },
  { name: 'bc', va: 0x02F1C7BC, rva: vaToRva(0x02F1C7BC) },
];

function createEnvelopeParser() {
  return {
    phase: 'soh',
    disabled: false,
    recordIndex: 0,
    recordTypeByte: null,
    payloadLength: null,
    lengthChars: '',
    payloadOffset: 0,
    tControl: [],
    eotObserved: null,
    checksumChars: '',
  };
}

function resetEnvelopeRecord(parser) {
  parser.phase = 'soh';
  parser.recordTypeByte = null;
  parser.payloadLength = null;
  parser.lengthChars = '';
  parser.payloadOffset = 0;
  parser.tControl = [];
  parser.eotObserved = null;
  parser.checksumChars = '';
}

function safePrintableType(value) {
  return Number.isInteger(value) && value >= 0x20 && value <= 0x7e
    ? String.fromCharCode(value)
    : null;
}

function isHexAscii(value) {
  return (value >= 0x30 && value <= 0x39)
    || (value >= 0x41 && value <= 0x46)
    || (value >= 0x61 && value <= 0x66);
}

function hexPair(chars) {
  if (chars.length !== 2 || !isHexAscii(chars.charCodeAt(0)) || !isHexAscii(chars.charCodeAt(1))) return null;
  return Number.parseInt(chars, 16);
}

function stopEnvelopeParser(parser, direction, reason, events) {
  if (parser.disabled) return;
  parser.disabled = true;
  events.push({
    type: 'serial_parser_stopped',
    direction,
    reason,
    parser_phase: parser.phase,
    record_type: safePrintableType(parser.recordTypeByte),
    declared_payload_bytes: parser.payloadLength,
    payload_bytes_skipped: parser.payloadOffset,
  });
}

// `readByteAt` is invoked only for envelope bytes, T body offsets 0..14,
// and EOT/checksum positions. Non-T body bytes are skipped arithmetically.
// No checksum is calculated; the two observed checksum characters are only
// recorded as an unverified field.
function feedEnvelope(parser, direction, actualLength, readByteAt) {
  const events = [];
  if (parser.disabled) return events;
  if (!Number.isInteger(actualLength) || actualLength < 0 || actualLength > MAX_IO_BYTES) {
    stopEnvelopeParser(parser, direction, 'io_length_out_of_range', events);
    return events;
  }

  let offset = 0;
  function takeByte(at) {
    try {
      const value = readByteAt(at);
      return Number.isInteger(value) && value >= 0 && value <= 0xff ? value : null;
    } catch (_) {
      return null;
    }
  }

  while (offset < actualLength && !parser.disabled) {
    if (parser.phase === 'soh') {
      const value = takeByte(offset++);
      if (value === null) { stopEnvelopeParser(parser, direction, 'envelope_byte_unreadable', events); continue; }
      if (value !== SOH) { stopEnvelopeParser(parser, direction, 'record_boundary_not_observed', events); continue; }
      parser.phase = 'type';
      continue;
    }

    if (parser.phase === 'type') {
      const value = takeByte(offset++);
      if (value === null) { stopEnvelopeParser(parser, direction, 'record_type_unreadable', events); continue; }
      parser.recordTypeByte = value;
      parser.phase = 'length';
      continue;
    }

    if (parser.phase === 'length') {
      const value = takeByte(offset++);
      if (value === null) { stopEnvelopeParser(parser, direction, 'length_byte_unreadable', events); continue; }
      if (!isHexAscii(value)) { stopEnvelopeParser(parser, direction, 'invalid_length_field', events); continue; }
      parser.lengthChars += String.fromCharCode(value);
      if (parser.lengthChars.length === 4) {
        parser.payloadLength = Number.parseInt(parser.lengthChars, 16);
        parser.phase = parser.payloadLength === 0 ? 'eot' : 'payload';
      }
      continue;
    }

    if (parser.phase === 'payload') {
      const remaining = parser.payloadLength - parser.payloadOffset;
      if (remaining <= 0) { parser.phase = 'eot'; continue; }
      const available = actualLength - offset;
      if (available <= 0) break;
      const isT = parser.recordTypeByte === 0x54;
      const controlRemaining = isT ? Math.max(0, 15 - parser.payloadOffset) : 0;
      if (controlRemaining > 0) {
        const count = Math.min(remaining, available, controlRemaining);
        for (let index = 0; index < count; index += 1) {
          const value = takeByte(offset++);
          if (value === null) { stopEnvelopeParser(parser, direction, 't_control_byte_unreadable', events); break; }
          parser.tControl.push(value);
          parser.payloadOffset += 1;
        }
      } else {
        const count = Math.min(remaining, available);
        // Deliberately do not call readByteAt for voice, G/header, or other body bytes.
        offset += count;
        parser.payloadOffset += count;
      }
      if (parser.payloadOffset >= parser.payloadLength) parser.phase = 'eot';
      continue;
    }

    if (parser.phase === 'eot') {
      const value = takeByte(offset++);
      if (value === null) { stopEnvelopeParser(parser, direction, 'eot_unreadable', events); continue; }
      parser.eotObserved = value === EOT;
      if (!parser.eotObserved) { stopEnvelopeParser(parser, direction, 'eot_not_observed_at_declared_boundary', events); continue; }
      parser.phase = 'checksum';
      continue;
    }

    if (parser.phase === 'checksum') {
      const value = takeByte(offset++);
      if (value === null) { stopEnvelopeParser(parser, direction, 'checksum_field_unreadable', events); continue; }
      parser.checksumChars += String.fromCharCode(value);
      if (parser.checksumChars.length < 2) continue;

      const checksumValue = hexPair(parser.checksumChars);
      parser.recordIndex += 1;
      const event = {
        type: 'serial_record',
        direction,
        record_index: parser.recordIndex,
        record_type: safePrintableType(parser.recordTypeByte),
        payload_bytes: parser.payloadLength,
        eot_observed: parser.eotObserved,
        declared_checksum_hex_unverified: checksumValue === null ? null : parser.checksumChars.toUpperCase(),
        checksum_syntax_valid: checksumValue !== null,
        checksum_verified: false,
        payload_disposition: 'omitted_except_T_control_offsets_0_to_14',
      };
      if (parser.recordTypeByte === 0x54) {
        event.t_control_prefix_u8 = parser.tControl.slice(0, 7);
        event.t_header_control_u8 = parser.tControl.slice(7, 15);
        event.t_control_bytes_read = parser.tControl.length;
      }
      events.push(event);
      resetEnvelopeRecord(parser);
      continue;
    }

    stopEnvelopeParser(parser, direction, 'unknown_parser_phase', events);
  }
  return events;
}

function entryStackArgument(esp, argumentIndex, readU32At) {
  if (!Number.isInteger(argumentIndex) || argumentIndex < 0) return null;
  try { return readU32At(esp.add(4 + argumentIndex * 4)); } catch (_) { return null; }
}

function signed16FromU32(value) {
  if (!Number.isInteger(value)) return null;
  return ((value & 0xffff) << 16) >> 16;
}

function pttArgumentsFromVerifiedCall(args, readU32At) {
  try {
    if (!args || args.length < 2) return null;
    const index = readU32At(args[0]);
    const rawValue = readU32At(args[1]);
    if (!Number.isInteger(index) || !Number.isInteger(rawValue)) return null;
    return { index: index >>> 0, value: signed16FromU32(rawValue) };
  } catch (_) { return null; }
}

function postThreadMessageFields(args, readU32At) {
  try {
    if (!args || args.length < 4) return null;
    const message = readU32At(args[1]);
    if (message !== 0x715) return null;
    return {
      message,
      wparam: readU32At(args[2]),
      lparam: readU32At(args[3]),
    };
  } catch (_) { return null; }
}

function waveOutHeaderMetadata(headerSize, readU32AtOffset) {
  if (headerSize !== WAVEHDR_X86_SIZE) return { status: 'unexpected_header_size', header_size: headerSize };
  try {
    // WAVEHDR offsets are fixed for x86. lpData at offset 0 is never dereferenced.
    const bufferLength = readU32AtOffset(4);
    const flags = readU32AtOffset(16);
    if (!Number.isInteger(bufferLength) || !Number.isInteger(flags)) return { status: 'metadata_unreadable' };
    return { status: 'observed', buffer_length: bufferLength >>> 0, flags: flags >>> 0 };
  } catch (_) { return { status: 'metadata_unreadable' }; }
}

function normalizePath(value) {
  try { return String(value || '').replace(/\\/g, '/').toLowerCase(); } catch (_) { return ''; }
}

function isNullPointer(value) {
  if (value === null || value === undefined) return true;
  try { return value.isNull(); } catch (_) { return true; }
}

function pointerU32(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return value >>> 0;
  try { return value.toUInt32() >>> 0; } catch (_) { return null; }
}

function matchesModuleRelativeAddress(address, moduleBase, rva) {
  const actual = pointerU32(address);
  const base = pointerU32(moduleBase);
  if (actual === null || base === null || !Number.isInteger(rva) || rva < 0) return false;
  return actual === ((base + rva) >>> 0);
}

function createAnonymousHandleTokenRegistry(limit = MAX_TRACKED_HANDLES) {
  const tokensByHandle = new Map();
  let nextToken = 1;
  return {
    tokenFor(handle) {
      if (handle === null || handle === undefined) return null;
      let key;
      try { key = typeof handle === 'string' ? handle : handle.toString(); } catch (_) { return null; }
      if (!key) return null;
      if (tokensByHandle.has(key)) return tokensByHandle.get(key);
      if (tokensByHandle.size >= limit) return null;
      const token = `W${nextToken++}`;
      tokensByHandle.set(key, token);
      return token;
    },
    get size() { return tokensByHandle.size; },
  };
}

function officialWriterMetadata(returnAddress, moduleBase, args, tokenRegistry) {
  if (!matchesModuleRelativeAddress(returnAddress, moduleBase, OFFICIAL_WRITER_RETURN_RVA)) return null;
  if (!args || args.length < 3 || !tokenRegistry) return null;
  return {
    handle_token: tokenRegistry.tokenFor(args[0]),
    requested_length_bytes: pointerU32(args[2]),
    payload_read: false,
  };
}

function win32CallSucceeded(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return (value | 0) !== 0;
  try { return value.toInt32() !== 0; } catch (_) { return null; }
}

function readableSpan(pointer, length) {
  if (isNullPointer(pointer) || !Number.isInteger(length) || length <= 0) return false;
  try {
    const range = Process.findRangeByAddress(pointer);
    if (!range || String(range.protection || '').indexOf('r') < 0) return false;
    const address = pointerU32(pointer), base = pointerU32(range.base), size = Number(range.size);
    if (address === null || base === null || !Number.isSafeInteger(size) || size < 0) return false;
    return address >= base && address + length <= base + size && address + length <= 0x100000000;
  } catch (_) { return false; }
}

function safeReadU8(pointer) {
  if (!readableSpan(pointer, 1)) return null;
  try { return pointer.readU8() & 0xff; } catch (_) { return null; }
}

function safeReadU32(pointer) {
  if (!readableSpan(pointer, 4)) return null;
  try { return pointer.readU32() >>> 0; } catch (_) { return null; }
}

function safeReadCodeHex(pointer, byteLength) {
  if (!readableSpan(pointer, byteLength)) return null;
  try {
    const bytes = pointer.readByteArray(byteLength);
    if (!bytes || bytes.byteLength !== byteLength) return null;
    return Array.from(new Uint8Array(bytes), (value) => value.toString(16).padStart(2, '0')).join('');
  } catch (_) { return null; }
}

function safePathString(pointer, wide) {
  if (isNullPointer(pointer)) return '';
  let output = '';
  const width = wide ? 2 : 1;
  for (let index = 0; index < 512; index += 1) {
    let value;
    if (wide) {
      if (!readableSpan(pointer.add(index * width), 2)) return '';
      try { value = pointer.add(index * width).readU16() & 0xffff; } catch (_) { return ''; }
    } else {
      value = safeReadU8(pointer.add(index));
      if (value === null) return '';
    }
    if (value === 0) return output;
    output += String.fromCharCode(value);
  }
  return '';
}

function isComPath(path) {
  let normalized = String(path || '').trim().replace(/\//g, '\\').toUpperCase();
  if (normalized.startsWith('\\\\.\\')) normalized = normalized.slice(4);
  return /^COM[0-9]+$/.test(normalized);
}

function isInvalidHandle(handle) {
  if (isNullPointer(handle)) return true;
  try { return handle.toUInt32() === 0xffffffff; } catch (_) { return false; }
}

function loadedModuleByName(modules, name) {
  const wanted = name.toLowerCase();
  return modules.find((module) => String(module.name || '').toLowerCase() === wanted) || null;
}

function resolveExport(moduleName, symbol) {
  try {
    if (typeof Module.getGlobalExportByName === 'function') {
      const address = Module.getGlobalExportByName(symbol);
      if (address && !isNullPointer(address)) return address;
    }
  } catch (_) {}
  try {
    if (typeof Module.findGlobalExportByName === 'function') {
      const address = Module.findGlobalExportByName(symbol);
      if (address && !isNullPointer(address)) return address;
    }
  } catch (_) {}
  try {
    const module = loadedModuleByName(Process.enumerateModules(), moduleName);
    if (module && typeof module.getExportByName === 'function') {
      const address = module.getExportByName(symbol);
      if (address && !isNullPointer(address)) return address;
    }
  } catch (_) {}
  try {
    if (typeof Module.findExportByName === 'function') {
      const address = Module.findExportByName(moduleName, symbol);
      if (address && !isNullPointer(address)) return address;
    }
  } catch (_) {}
  return null;
}

let stopped = false;
let active = false;
let startedAtMs = 0;
let sequence = 0;
let totalEvents = 0;
let serialRecordCount = 0;
let nextHandleId = 1;
let stopTimer = null;
const listeners = [];
const hookCoverage = [];
const serialHandles = new Map();
const writerHandleTokens = createAnonymousHandleTokenRegistry(MAX_TRACKED_HANDLES);

function emit(type, fields = {}) {
  const finalEvent = type === 'observer_stopped' || type === 'serial_partial_record_dropped' || type === 'observer_unavailable';
  if (stopped && !finalEvent) return;
  if (totalEvents >= MAX_EVENTS && type !== 'observer_stopped') {
    stopObserver('max_event_count_reached');
    return;
  }
  totalEvents += 1;
  try {
    send({
      observer: OBSERVER_NAME,
      sequence: ++sequence,
      host_time_utc: new Date().toISOString(),
      elapsed_ms: active ? Math.max(0, Date.now() - startedAtMs) : 0,
      type,
      ...fields,
    });
  } catch (_) {}
}

function attachHook(label, moduleName, address, callback, required, rva = null) {
  const result = { label, module: moduleName, rva: rva === null ? null : `0x${rva.toString(16)}`, required, status: 'attach_failed' };
  if (!address || isNullPointer(address)) {
    result.status = 'export_unavailable';
    hookCoverage.push(result);
    return false;
  }
  try {
    const listener = Interceptor.attach(address, callback);
    listeners.push(listener);
    result.status = 'attached';
  } catch (_) { result.status = 'attach_failed'; }
  hookCoverage.push(result);
  return result.status === 'attached';
}

function verifyExeTarget(main, target) {
  if (!Number.isInteger(target.rva) || target.rva < 0 || target.rva + target.signature.length / 2 > Number(main.size)) {
    return { ok: false, reason: 'rva_outside_main_module' };
  }
  const address = main.base.add(target.rva);
  const observed = safeReadCodeHex(address, target.signature.length / 2);
  if (observed === null) return { ok: false, reason: 'entry_bytes_unreadable' };
  if (observed !== target.signature) return { ok: false, reason: 'entry_signature_mismatch' };
  return { ok: true, address };
}

function readModuleGlobalU32(main, rva) {
  if (!Number.isInteger(rva) || rva < 0 || rva + 4 > Number(main.size)) return null;
  return safeReadU32(main.base.add(rva));
}

function connectRowAtEntry(context, argumentIndex) {
  try { return entryStackArgument(context.esp, argumentIndex, safeReadU32); } catch (_) { return null; }
}

function safeReadBufferByte(buffer, offset) {
  if (!Number.isInteger(offset) || offset < 0) return null;
  try { return safeReadU8(buffer.add(offset)); } catch (_) { return null; }
}

function disableSerialDirection(handleState, direction, reason) {
  const parser = handleState.parsers[direction];
  if (parser.disabled) return;
  parser.disabled = true;
  emit('serial_parser_stopped', {
    handle_id: handleState.id,
    direction,
    reason,
    parser_phase: parser.phase,
    record_type: safePrintableType(parser.recordTypeByte),
    declared_payload_bytes: parser.payloadLength,
    payload_bytes_skipped: parser.payloadOffset,
  });
}

function handleSerialIo(state, direction, buffer, requested, countPointer, overlapped, success) {
  if (state.parsers[direction].disabled) return;
  if (overlapped) { disableSerialDirection(state, direction, 'overlapped_completion_not_observed'); return; }
  if (!success) { disableSerialDirection(state, direction, 'synchronous_io_failed'); return; }
  const actual = safeReadU32(countPointer);
  if (actual === null || actual > requested) { disableSerialDirection(state, direction, 'actual_io_count_unavailable_or_invalid'); return; }
  if (actual > MAX_IO_BYTES) { disableSerialDirection(state, direction, 'actual_io_count_over_limit'); return; }

  const parserEvents = feedEnvelope(
    state.parsers[direction], direction, actual,
    (offset) => safeReadBufferByte(buffer, offset),
  );
  for (const event of parserEvents) {
    if (event.type === 'serial_record') {
      serialRecordCount += 1;
      emit('serial_record', { handle_id: state.id, ...event });
      if (serialRecordCount >= MAX_SERIAL_RECORDS) { stopObserver('max_serial_record_count_reached'); return; }
    } else {
      emit(event.type, { handle_id: state.id, ...event });
    }
  }
}

function hookCreateFile(apiName, wide) {
  const address = resolveExport('kernel32.dll', apiName);
  return attachHook(apiName, 'kernel32.dll', address, {
    onEnter(args) { this.isCom = isComPath(safePathString(args[0], wide)); },
    onLeave(retval) {
      if (!this.isCom || isInvalidHandle(retval)) return;
      const key = retval.toString();
      if (serialHandles.has(key)) return;
      if (serialHandles.size >= MAX_TRACKED_HANDLES) { emit('serial_handle_ignored', { reason: 'handle_limit' }); return; }
      const state = {
        id: `C${nextHandleId++}`,
        parsers: { tx: createEnvelopeParser(), rx: createEnvelopeParser() },
      };
      serialHandles.set(key, state);
      emit('serial_handle_open', { handle_id: state.id, port_name_recorded: false });
    },
  }, false);
}

function hookSerialIo(apiName, direction) {
  const address = resolveExport('kernel32.dll', apiName);
  return attachHook(apiName, 'kernel32.dll', address, {
    onEnter(args) {
      this.state = serialHandles.get(args[0].toString()) || null;
      if (!this.state) return;
      this.buffer = args[1];
      this.requested = pointerU32(args[2]);
      this.countPointer = args[3];
      this.overlapped = !isNullPointer(args[4]);
    },
    onLeave(retval) {
      if (!this.state) return;
      if (this.requested === null) { disableSerialDirection(this.state, direction, 'requested_io_count_unavailable'); return; }
      handleSerialIo(this.state, direction, this.buffer, this.requested, this.countPointer, this.overlapped, retval.toInt32() !== 0);
    },
  }, false);
}

function attachOfficialWriterMetadataHook(main) {
  const result = {
    label: 'WriteFile_return_0xF7FA',
    module: 'kernel32.dll',
    caller_module: 'WIRES-X.exe',
    return_rva: `0x${OFFICIAL_WRITER_RETURN_RVA.toString(16)}`,
    required: false,
    status: 'attach_failed',
  };
  const verifiedCallsite = verifyExeTarget(main, {
    rva: OFFICIAL_WRITER_CALLSITE_RVA,
    signature: OFFICIAL_WRITER_CALLSITE_SIGNATURE,
  });
  if (!verifiedCallsite.ok || OFFICIAL_WRITER_RETURN_RVA !== OFFICIAL_WRITER_CALLSITE_RVA + 6) {
    result.status = verifiedCallsite.ok ? 'return_address_mismatch' : verifiedCallsite.reason;
    hookCoverage.push(result);
    return false;
  }

  const address = resolveExport('kernel32.dll', 'WriteFile');
  if (!address || isNullPointer(address)) {
    result.status = 'export_unavailable';
    hookCoverage.push(result);
    return false;
  }
  try {
    const listener = Interceptor.attach(address, {
      onEnter(args) {
        // 仅比较 API 调用的返回地址；只读 handle 与请求长度，不读取 lpBuffer。
        this.r110WriterMetadata = officialWriterMetadata(
          this.returnAddress, main.base, args, writerHandleTokens,
        );
      },
      onLeave(retval) {
        if (!this.r110WriterMetadata) return;
        emit('official_writer_write_metadata', {
          ...this.r110WriterMetadata,
          write_succeeded: win32CallSucceeded(retval),
        });
      },
    });
    listeners.push(listener);
    result.status = 'attached';
  } catch (_) {
    result.status = 'attach_failed';
  }
  hookCoverage.push(result);
  return result.status === 'attached';
}

function hookCloseHandle() {
  const address = resolveExport('kernel32.dll', 'CloseHandle');
  return attachHook('CloseHandle', 'kernel32.dll', address, {
    onEnter(args) { this.key = args[0].toString(); this.state = serialHandles.get(this.key) || null; },
    onLeave(retval) {
      if (!this.state || retval.toInt32() === 0) return;
      serialHandles.delete(this.key);
      emit('serial_handle_closed', { handle_id: this.state.id });
    },
  }, false);
}

function attachMainHooks(main) {
  for (const target of EXE_TARGETS) {
    const verified = verifyExeTarget(main, target);
    if (!verified.ok) {
      hookCoverage.push({ label: target.name, module: 'WIRES-X.exe', rva: `0x${target.rva.toString(16)}`, required: true, status: verified.reason });
      continue;
    }
    const callbacks = {
      onEnter() {
        if (target.name === 'ConnectCntl') {
          // Verified in EXE: StartRcvVoice pushes row first, string second;
          // ConnectCntl indexes the table with stack argument 1 at [ESP+8].
          const row = connectRowAtEntry(this.context, target.rowStackArgument);
          emit('exe_function_entry', { function: target.name, row });
        } else if (target.gateSnapshot) {
          // Only these image-relative globals are read; ECX/ESI/owner are not.
          const modeGlobals = {};
          for (const item of MODE_GLOBALS) modeGlobals[item.name] = readModuleGlobalU32(main, item.rva);
          emit('exe_function_entry', { function: target.name, mode_globals: modeGlobals });
        } else {
          emit('exe_function_entry', { function: target.name });
        }
      },
    };
    if (target.returnCode) {
      callbacks.onLeave = function (retval) {
        let returnCode = null;
        try { returnCode = retval.toInt32(); } catch (_) {}
        emit('exe_function_return', { function: target.name, return_code: returnCode });
      };
    }
    attachHook(target.name, 'WIRES-X.exe', verified.address, callbacks, true, target.rva);
  }
}

function attachPttExport() {
  const address = resolveExport('HRI-UART.dll', 'SendTrcvPttCmd');
  return attachHook('SendTrcvPttCmd', 'HRI-UART.dll', address, {
    onEnter(args) {
      // Caller-side EXE instructions push the short value, then index 0 before
      // CALL EAX; the HRI export signature is (int index, short value).
      const request = pttArgumentsFromVerifiedCall(args, pointerU32);
      emit('hri_ptt_request', request || { arguments_read: false });
    },
  }, true);
}

function attachPostThreadMessage() {
  const address = resolveExport('user32.dll', 'PostThreadMessageA');
  return attachHook('PostThreadMessageA', 'user32.dll', address, {
    onEnter(args) {
      // Win32 signature: (threadId, msg, wParam, lParam). The thread id is omitted.
      const fields = postThreadMessageFields(args, pointerU32);
      if (fields) emit('thread_message_715', fields);
    },
  }, false);
}

function attachWaveOutWrite() {
  const address = resolveExport('winmm.dll', 'waveOutWrite');
  return attachHook('waveOutWrite', 'winmm.dll', address, {
    onEnter(args) {
      const headerSize = pointerU32(args[2]);
      const metadata = waveOutHeaderMetadata(headerSize, (offset) => safeReadU32(args[1].add(offset)));
      emit('waveout_write_metadata', metadata);
    },
  }, false);
}

function detachOwnHooks() {
  let detached = 0;
  for (const listener of listeners.splice(0)) {
    try { listener.detach(); detached += 1; } catch (_) {}
  }
  return detached;
}

function stopObserver(reason) {
  if (stopped) return;
  stopped = true;
  active = false;
  if (stopTimer !== null) { try { clearTimeout(stopTimer); } catch (_) {} stopTimer = null; }
  for (const [key, state] of serialHandles.entries()) {
    for (const direction of ['tx', 'rx']) {
      const parser = state.parsers[direction];
      if (!parser.disabled && parser.phase !== 'soh') {
        emit('serial_partial_record_dropped', {
          handle_id: state.id,
          direction,
          parser_phase: parser.phase,
          record_type: safePrintableType(parser.recordTypeByte),
          declared_payload_bytes: parser.payloadLength,
          payload_bytes_skipped: parser.payloadOffset,
        });
      }
    }
    serialHandles.delete(key);
  }
  const detached = detachOwnHooks();
  emit('observer_stopped', { reason, own_hooks_detached: detached, serial_record_count: serialRecordCount });
}

function unavailable(reason, details = {}) {
  active = false;
  emit('observer_unavailable', {
    status: 'unavailable',
    reason,
    pointer_size: typeof Process === 'undefined' ? null : Process.pointerSize,
    main_hash_preflight_required: MAIN_SHA256,
    hri_hash_preflight_required: HRI_SHA256,
    runtime_module_hash_verified: false,
    ...details,
  });
  stopped = true;
}

function bootstrap() {
  if (Process.pointerSize !== 4) { unavailable('unsupported_pointer_size'); return; }
  let main;
  let modules;
  try {
    main = Process.mainModule;
    modules = Process.enumerateModules();
  } catch (_) { unavailable('module_enumeration_failed'); return; }
  if (!main || normalizePath(main.path || main.name) !== TARGET_MAIN_PATH) {
    unavailable('main_module_path_mismatch');
    return;
  }
  const hri = modules.find((module) => normalizePath(module.path || module.name) === TARGET_HRI_PATH);
  if (!hri) { unavailable('target_hri_module_not_loaded'); return; }

  attachMainHooks(main);
  attachPttExport();
  attachPostThreadMessage();
  attachWaveOutWrite();
  hookCreateFile('CreateFileA', false);
  hookCreateFile('CreateFileW', true);
  attachOfficialWriterMetadataHook(main);
  hookSerialIo('ReadFile', 'rx');
  hookCloseHandle();

  if (listeners.length === 0) { unavailable('no_hooks_attached', { hook_coverage: hookCoverage }); return; }
  startedAtMs = Date.now();
  active = true;
  const allAttached = hookCoverage.every((item) => item.status === 'attached' || !item.required);
  emit(allAttached ? 'observer_started' : 'observer_partial', {
    status: allAttached ? 'complete' : 'partial',
    target_pointer_size: Process.pointerSize,
    image_base_preferred: '0x00400000',
    address_mode: 'runtime_module_base_plus_va_minus_static_image_base',
    window_ms: MAX_CAPTURE_MS,
    hook_coverage: hookCoverage,
    audio_samples_read: false,
    serial_body_bytes_read: 'T offsets 0..14 only; all other record bodies skipped',
    runtime_module_hash_verified: false,
  });
  stopTimer = setTimeout(() => stopObserver('time_limit_25_seconds'), MAX_CAPTURE_MS);
}

if (typeof Process === 'undefined') {
  // Pure functions are exposed only to the Node offline fixture, never in Frida.
  if (typeof globalThis !== 'undefined' && globalThis.__R110_OFFLINE_TEST__ === true) {
    globalThis.__R110_OFFLINE_API__ = {
      IMAGE_BASE,
      OFFICIAL_WRITER_CALLSITE_VA,
      OFFICIAL_WRITER_CALLSITE_RVA,
      OFFICIAL_WRITER_CALLSITE_SIGNATURE,
      OFFICIAL_WRITER_RETURN_VA,
      OFFICIAL_WRITER_RETURN_RVA,
      EXE_TARGETS: EXE_TARGETS.map(({ name, va, rva, signature }) => ({ name, va, rva, signature })),
      MODE_GLOBALS: MODE_GLOBALS.map(({ name, va, rva }) => ({ name, va, rva })),
      createEnvelopeParser,
      feedEnvelope,
      entryStackArgument,
      pttArgumentsFromVerifiedCall,
      postThreadMessageFields,
      waveOutHeaderMetadata,
      hexPair,
      isComPath,
      matchesModuleRelativeAddress,
      createAnonymousHandleTokenRegistry,
      officialWriterMetadata,
      win32CallSucceeded,
    };
  }
} else {
  bootstrap();
}
