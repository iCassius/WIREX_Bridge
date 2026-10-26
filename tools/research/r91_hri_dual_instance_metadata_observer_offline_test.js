'use strict';

// R91 离线合成测试：在 Node VM 中模拟 Frida 只读 API，不附加或启动任何目标进程。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, 'r91_hri_dual_instance_metadata_observer.js'), 'utf8');

const MAIN_PATH = 'C:\\Program Files (x86)\\YAESUMUSEN\\WIRES-X\\WIRES-X.exe';
const HRI_PATH = 'C:\\Program Files (x86)\\YAESUMUSEN\\WIRES-X\\HRI-UART.dll';
const RIGDATAIF_PATH = 'C:\\Program Files (x86)\\YAESUMUSEN\\WIRES-X\\RigDataIf.dll';
const HRI_BASE = 0x69b00000;
const RIGDATAIF_BASE = 0x6a000000;
const TABLE_RVA = 0x191d38;
const OBJECTS = [0x60000000, 0x60006000];
const CHILDREN = [0x60001000, 0x60007000];
const RECORD_CONTEXTS = [0x60002000, 0x60008000];
const FACTORY_OBJECTS = [0x60003000, 0x60009000];
const VTABLES = [0x60004000, 0x6000a000];
const CALLBACK_TABLES = [0x60005000, 0x6000b000];

class FakePointer {
  constructor(value, runtime) { this.value = Number(value) >>> 0; this.runtime = runtime; }
  toString() { return '0x' + this.value.toString(16); }
  toUInt32() { return this.value >>> 0; }
  isNull() { return this.value === 0; }
  add(offset) { return this.runtime.pointer((this.value + offset) >>> 0); }
  readPointer() { return this.runtime.pointer(this.runtime.readU32(this.value)); }
  readU32() { return this.runtime.readU32(this.value); }
  readU8() { return this.runtime.readU8(this.value); }
  readByteArray(length) { return this.runtime.readByteArray(this.value, length); }
}

function makeRuntime(opts = {}) {
  const r = {
    now: 0, events: [], bytes: new Map(), ranges: [], modules: [], timers: new Map(), nextTimer: 1,
    attachCount: 0, exportCallCount: 0, memoryReadBytes: 0, memoryWriteBytes: 0,
    readU8Addresses: [], deadPointerRangeQueries: 0
  };
  r.pointer = (value) => new FakePointer(value, r);
  r.writeU8 = (address, value) => {
    const a = Number(address) >>> 0;
    r.memoryWriteBytes += 1;
    r.bytes.set(a, Number(value) & 0xff);
  };
  r.writeU32 = (address, value) => {
    const v = Number(value) >>> 0, a = Number(address) >>> 0;
    r.memoryWriteBytes += 4;
    for (let i = 0; i < 4; i += 1) r.bytes.set((a + i) >>> 0, (v >>> (8 * i)) & 0xff);
  };
  r.readU8 = (address) => {
    const a = Number(address) >>> 0;
    if (!r.bytes.has(a)) throw Error('unmapped byte');
    r.memoryReadBytes += 1;
    r.readU8Addresses.push(a);
    return r.bytes.get(a);
  };
  r.readU32 = (address) => {
    const a = Number(address) >>> 0;
    let value = 0;
    for (let i = 0; i < 4; i += 1) {
      if (!r.bytes.has((a + i) >>> 0)) throw Error('unmapped dword');
      value |= r.bytes.get((a + i) >>> 0) << (8 * i);
    }
    r.memoryReadBytes += 4;
    return value >>> 0;
  };
  r.readByteArray = (address, length) => {
    const result = new Uint8Array(length);
    for (let i = 0; i < length; i += 1) result[i] = r.readU8(Number(address) + i);
    return result.buffer;
  };

  class FakeDate extends Date {
    constructor(...args) { super(...(args.length ? args : [r.now])); }
    static now() { return r.now; }
  }
  const Process = {
    pointerSize: opts.pointerSize || 4,
    get mainModule() { return r.mainModule || null; },
    enumerateModules() { if (opts.enumerateThrows) throw Error('enumeration failure'); return r.modules.slice(); },
    findRangeByAddress(pointer) {
      const address = pointer.toUInt32();
      if (address === 0xdeadbeef) r.deadPointerRangeQueries += 1;
      return r.ranges.find((x) => address >= x.base.toUInt32() && address < x.base.toUInt32() + x.size) || null;
    },
    findModuleByAddress(pointer) {
      const address = pointer.toUInt32();
      return r.modules.find((x) => address >= x.base.toUInt32() && address < x.base.toUInt32() + x.size) || null;
    }
  };
  r.context = vm.createContext({
    Process,
    Interceptor: { attach() { r.attachCount += 1; throw Error('observer must not hook'); } },
    Module: { findExportByName() { r.exportCallCount += 1; throw Error('observer must not resolve/call exports'); } },
    send(event) { r.events.push(JSON.parse(JSON.stringify(event))); },
    Date: FakeDate, String, Number, Object, Array, Math, JSON, Error, Map, Uint8Array,
    setTimeout(callback, delay) {
      const id = r.nextTimer++;
      r.timers.set(id, { id, callback, due: r.now + delay, cleared: false });
      return id;
    },
    clearTimeout(id) { const timer = r.timers.get(id); if (timer) timer.cleared = true; }
  });
  r.run = () => vm.runInContext(source, r.context, { filename: 'r91_hri_dual_instance_metadata_observer.js' });
  r.addRange = (base, size, protection) => r.ranges.push({ base: r.pointer(base), size, protection });
  r.addModule = (base, size, fullPath, name) => {
    const module = { base: r.pointer(base), size, path: fullPath, name };
    r.modules.push(module);
    return module;
  };
  r.next = () => {
    const timer = [...r.timers.values()].filter((x) => !x.cleared).sort((a, b) => a.due - b.due)[0];
    assert.ok(timer, 'an active timer should exist');
    r.timers.delete(timer.id);
    r.now = timer.due;
    timer.callback();
  };
  r.until = (ms) => {
    const end = r.now + ms;
    while ([...r.timers.values()].some((x) => !x.cleared && x.due <= end)) r.next();
    r.now = end;
  };
  return r;
}

function setMainOnly(r, mainPath = MAIN_PATH) {
  const main = r.addModule(0x00400000, 0x500000, mainPath, 'WIRES_X.exe');
  r.mainModule = main;
  r.addRange(0x00400000, 0x500000, 'r-x');
  return main;
}

function addHriModule(r) {
  const hri = r.addModule(HRI_BASE, 0x1a0000, HRI_PATH, 'HRI-UART.dll');
  r.addRange(HRI_BASE, 0x1a0000, 'r-x');
  r.writeU32(HRI_BASE + TABLE_RVA, OBJECTS[0]);
  r.writeU32(HRI_BASE + TABLE_RVA + 4, OBJECTS[1]);
  return hri;
}

function addRigDataIfModule(r, hriCount = 7, anaCount = 13) {
  const rigdataif = r.addModule(RIGDATAIF_BASE, 0x1a0000, RIGDATAIF_PATH, 'RigDataIf.dll');
  r.addRange(RIGDATAIF_BASE, 0x1a0000, 'r-x');
  r.writeU32(RIGDATAIF_BASE + 0x16830c, 0xdeadbeef);
  r.writeU32(RIGDATAIF_BASE + 0x16831c, hriCount);
  r.writeU32(RIGDATAIF_BASE + 0x168324, 0xdeadbeef);
  r.writeU32(RIGDATAIF_BASE + 0x168334, anaCount);
  return rigdataif;
}

function addObjectRanges(r) {
  for (let i = 0; i < 2; i += 1) {
    r.addRange(OBJECTS[i], 0x3000, 'rw-');
    r.addRange(OBJECTS[i] + 0x1d000, 0x1000, 'rw-');
    r.addRange(CHILDREN[i], 0x1000, 'rw-');
    r.addRange(RECORD_CONTEXTS[i], 0x1000, 'rw-');
    r.addRange(FACTORY_OBJECTS[i], 0x1000, 'rw-');
    r.addRange(VTABLES[i], 0x1000, 'rw-');
    r.addRange(CALLBACK_TABLES[i], 0x1000, 'rw-');
  }
}

function setTarget(r, mainPath = MAIN_PATH) {
  const main = setMainOnly(r, mainPath);
  const hri = addHriModule(r);
  const rigdataif = addRigDataIfModule(r);
  addObjectRanges(r);
  return { main, hri, rigdataif };
}

function setObjectGraph(r, slot, values = {}) {
  const object = OBJECTS[slot], child = CHILDREN[slot], record = RECORD_CONTEXTS[slot];
  const factory = FACTORY_OBJECTS[slot], vtable = VTABLES[slot], callbacks = CALLBACK_TABLES[slot];
  const defaults = slot === 0
    ? { field44: 5, field50: 0x1234, field58: 0x2345, field1d4: 0x11223344, field1dc: 0x55667788, field28f8: 2, field28e4: 0, field28e8: 100, child2c4: 11, child2bc: 12, record10: 0xaabbccdd }
    : { field44: 9, field50: 0x3456, field58: 0x4567, field1d4: 0x99aabbcc, field1dc: 0xddeeff00, field28f8: 0, field28e4: 2, field28e8: 200, child2c4: 13, child2bc: 14, record10: 0x12345678 };
  const get = (name) => values[name] === undefined ? defaults[name] : values[name];
  r.writeU32(object + 0x44, get('field44'));
  r.writeU32(object + 0x50, get('field50'));
  r.writeU32(object + 0x58, get('field58'));
  r.writeU32(object + 0x1d4, get('field1d4'));
  r.writeU32(object + 0x1dc, get('field1dc'));
  r.writeU32(object + 0x28f8, get('field28f8'));
  r.writeU32(object + 0x28e4, get('field28e4'));
  r.writeU32(object + 0x28e8, get('field28e8'));
  r.writeU8(object + 0x248c, values.field248c === undefined ? 1 : values.field248c);
  r.writeU32(object + 0x2b8, child);
  r.writeU32(child, HRI_BASE + 0x9f20);
  r.writeU32(child + 0x2c4, get('child2c4'));
  r.writeU32(child + 0x2bc, get('child2bc'));
  r.writeU32(object + 0x2b4, record);
  r.writeU32(record + 0x10, get('record10'));
  r.writeU32(record + 0x14, factory);
  r.writeU32(factory, vtable);
  r.writeU32(vtable, HRI_BASE + 0x9f20);
  r.writeU32(vtable + 4, HRI_BASE + 0x9fe0);
  r.writeU32(object + 0x1d8ec, callbacks);
  r.writeU32(callbacks + 0x44, RIGDATAIF_BASE + 0x2950);
  r.writeU32(callbacks + 0x48, RIGDATAIF_BASE + 0x2980);
  r.writeU32(callbacks + 0x64, RIGDATAIF_BASE + 0x2a40);
  r.writeU32(callbacks + 0x68, RIGDATAIF_BASE + 0x2a70);
  for (let index = 0; index < 512; index += 1) r.writeU8(object + 0x1420 + index, 0x41);
  const header = values.header || [0x41, 0x42, 0x43, 0x00, 0x44];
  header.forEach((byte, index) => r.writeU8(object + 0x1420 + index, byte));
}

function of(runtime, type) { return runtime.events.filter((event) => event.type === type); }

function testBothInstanceSlotsAndRawFields() {
  const r = makeRuntime();
  setTarget(r);
  setObjectGraph(r, 0, { header: [0x53, 0x45, 0x43, 0x52, 0x45, 0x54, 0x00, 0x78] });
  setObjectGraph(r, 1);
  const writesBefore = r.memoryWriteBytes;
  r.run();
  const event = of(r, 'first_dual_instance_metadata_snapshot')[0];
  assert.ok(event);
  const snapshot = event.snapshot;
  assert.equal(snapshot.expected_main_sha256, '8f05dc26794144438566b880ce775f5178d62eb3c4deb8c053089216342bc671');
  assert.equal(snapshot.runtime_module_hash_verified, false);
  assert.equal(snapshot.instance_table_slot_count, 2);
  assert.deepEqual(snapshot.instances.map((x) => x.instance_table_slot), [0, 1]);

  const slot0 = snapshot.instances[0], slot1 = snapshot.instances[1];
  assert.equal(slot0.trcvtype_0x50_raw_u32.value, 0x1234);
  assert.equal(slot0.ope_mode_0x58_raw_u32.value, 0x2345);
  assert.equal(slot0.hri_0x1d4_raw_u32.value, 0x11223344);
  assert.equal(slot0.hri_0x1dc_raw_u32.value, 0x55667788);
  assert.equal(slot0.record_context_plus_0x10_raw_u32.value, 0xaabbccdd);
  assert.equal(slot0.child_vtable.rva, '0x9f20');
  assert.equal(slot0.selected_queue_callback_metadata.get_callback_offset, '0x44');
  assert.equal(slot0.selected_queue_callback_metadata.get_callback.rva, '0x2950');
  assert.equal(slot0.selected_queue_count_metadata.count32, 7);
  assert.equal(slot0.header_length_only.nul_terminated_length, 6);
  assert.equal(slot1.trcvtype_0x50_raw_u32.value, 0x3456);
  assert.equal(slot1.ope_mode_0x58_raw_u32.value, 0x4567);
  assert.equal(slot1.hri_0x1d4_raw_u32.value, 0x99aabbcc);
  assert.equal(slot1.hri_0x1dc_raw_u32.value, 0xddeeff00);
  assert.equal(slot1.record_context_plus_0x10_raw_u32.value, 0x12345678);
  assert.equal(slot1.child_vtable.rva, '0x9f20');
  assert.equal(slot1.selected_queue_callback_metadata.get_callback_offset, '0x64');
  assert.equal(slot1.selected_queue_callback_metadata.get_callback.rva, '0x2a40');
  assert.equal(slot1.selected_queue_count_metadata.count32, 13);
  assert.equal(snapshot.rigdataif_queue_metadata.count32, 7);
  assert.equal(snapshot.rigdataif_ana_queue_metadata.count32, 13);
  assert.equal(r.deadPointerRangeQueries, 0, 'queue head must not be followed');
  assert.equal(JSON.stringify(r.events).includes('SECRET'), false, 'header contents must not be emitted');
  assert.deepEqual(r.readU8Addresses.filter((address) => address >= OBJECTS[0] + 0x1420 && address < OBJECTS[0] + 0x1420 + 512), [
    OBJECTS[0] + 0x1420, OBJECTS[0] + 0x1421, OBJECTS[0] + 0x1422, OBJECTS[0] + 0x1423,
    OBJECTS[0] + 0x1424, OBJECTS[0] + 0x1425, OBJECTS[0] + 0x1426
  ], 'header scan stops immediately after reading NUL');
  assert.equal(r.memoryWriteBytes, writesBefore, 'observer must not write target memory');
  assert.equal(r.attachCount, 0);
  assert.equal(r.exportCallCount, 0);
  r.until(10000);
  assert.equal(of(r, 'observer_summary')[0].sample_count, 100);
  assert.equal(of(r, 'observer_stopped')[0].reason, 'time_limit_10_seconds');
}

function testBadSlotIsIsolatedFromOtherInstance() {
  const r = makeRuntime();
  setTarget(r);
  setObjectGraph(r, 1);
  r.writeU32(HRI_BASE + TABLE_RVA, 0xdeadbeef);
  r.run();
  const snapshot = of(r, 'first_dual_instance_metadata_snapshot')[0].snapshot;
  assert.equal(snapshot.instances[0].object_read_reason, 'unmapped_address');
  assert.equal(snapshot.instances[1].object_read_reason, null);
  assert.equal(snapshot.instances[1].trcvtype_0x50_raw_u32.value, 0x3456);
  assert.equal(r.deadPointerRangeQueries, 1, 'only the invalid slot pointer is range checked; queue heads are not followed');
  r.until(10000);
}

function testNullSlotAndUnreadableTableAreExplicit() {
  const nullSlot = makeRuntime();
  setTarget(nullSlot);
  setObjectGraph(nullSlot, 0);
  setObjectGraph(nullSlot, 1);
  nullSlot.writeU32(HRI_BASE + TABLE_RVA, 0);
  nullSlot.run();
  let snapshot = of(nullSlot, 'first_dual_instance_metadata_snapshot')[0].snapshot;
  assert.equal(snapshot.instances[0].object_read_reason, 'instance_slot_is_null');
  assert.equal(snapshot.instances[1].object_read_reason, null);
  nullSlot.until(10000);

  const shortTable = makeRuntime();
  setTarget(shortTable);
  setObjectGraph(shortTable, 0);
  setObjectGraph(shortTable, 1);
  shortTable.ranges = shortTable.ranges.filter((x) => x.base.toUInt32() !== HRI_BASE);
  shortTable.addRange(HRI_BASE, TABLE_RVA + 4, 'r-x');
  shortTable.run();
  snapshot = of(shortTable, 'first_dual_instance_metadata_snapshot')[0].snapshot;
  assert.notEqual(snapshot.instance_table_read_reason, null);
  assert.equal(snapshot.instances[0].object_address, null);
  assert.equal(snapshot.instances[1].object_address, null);
  shortTable.until(10000);
}

function testTargetPathWidthAndDelayedModuleGates() {
  const wrong = makeRuntime();
  setTarget(wrong, 'C:\\Program Files (x86)\\YAESUMUSEN\\WIRES-X\\other.exe');
  wrong.run();
  assert.equal(of(wrong, 'target_rejected')[0].reason, 'main_module_path_mismatch');
  assert.equal(wrong.memoryReadBytes, 0);

  const x64 = makeRuntime({ pointerSize: 8 });
  setTarget(x64);
  x64.run();
  assert.equal(of(x64, 'target_rejected')[0].reason, 'unexpected_pointer_size');
  assert.equal(x64.memoryReadBytes, 0);

  const delayed = makeRuntime();
  setMainOnly(delayed);
  delayed.context.setTimeout(() => {
    addHriModule(delayed);
    addRigDataIfModule(delayed);
    addObjectRanges(delayed);
    setObjectGraph(delayed, 0);
    setObjectGraph(delayed, 1);
  }, 500);
  delayed.run();
  delayed.until(400);
  assert.equal(of(delayed, 'target_rejected').length, 0);
  assert.equal(of(delayed, 'first_dual_instance_metadata_snapshot').length, 0);
  delayed.until(200);
  assert.equal(of(delayed, 'first_dual_instance_metadata_snapshot').length, 1);
  delayed.until(9400);
  assert.equal(of(delayed, 'observer_stopped')[0].reason, 'time_limit_10_seconds');
}

function testChangeEventsAreBoundedAndKeepLatestSummary() {
  const r = makeRuntime();
  setTarget(r);
  setObjectGraph(r, 0);
  setObjectGraph(r, 1);
  r.run();
  for (let index = 1; index <= 20; index += 1) {
    r.writeU32(OBJECTS[1] + 0x50, 0x4000 + index);
    r.next();
  }
  assert.equal(of(r, 'dual_instance_metadata_changed').length, 16);
  r.until(8000);
  const summary = of(r, 'observer_summary')[0];
  assert.equal(summary.changed_sample_count, 20);
  assert.equal(summary.omitted_change_events, 4);
  assert.equal(summary.first_snapshot.instances[1].trcvtype_0x50_raw_u32.value, 0x3456);
  assert.equal(summary.last_snapshot.instances[1].trcvtype_0x50_raw_u32.value, 0x4000 + 20);
}

testBothInstanceSlotsAndRawFields();
testBadSlotIsIsolatedFromOtherInstance();
testNullSlotAndUnreadableTableAreExplicit();
testTargetPathWidthAndDelayedModuleGates();
testChangeEventsAreBoundedAndKeepLatestSummary();
process.stdout.write('R91 dual-instance observer offline checks passed: slots 0/1, raw constructor/config fields, recordctx+0x10, child vtable RVA, selected queue metadata, bounded NUL scan, target gates, slot isolation, no hooks/calls/writes\n');
