'use strict';

// Offline-only tests. The observer source is evaluated without Frida globals,
// so no process can be attached and no target API can be called.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const observerPath = path.join(__dirname, 'r110_official_rx_path_observer.js');
const context = { __R110_OFFLINE_TEST__: true };
vm.runInNewContext(fs.readFileSync(observerPath, 'utf8'), context, { filename: observerPath });
const api = context.__R110_OFFLINE_API__;
assert.ok(api, 'offline pure-function interface was not exported');
const plain = (value) => JSON.parse(JSON.stringify(value));

assert.equal(api.IMAGE_BASE, 0x00400000);
assert.equal(api.OFFICIAL_WRITER_CALLSITE_VA, 0x0040F7F4);
assert.equal(api.OFFICIAL_WRITER_CALLSITE_RVA, 0x0000F7F4);
assert.equal(api.OFFICIAL_WRITER_CALLSITE_SIGNATURE, 'ff156c967000');
assert.equal(api.OFFICIAL_WRITER_RETURN_VA, 0x0040F7FA);
assert.equal(api.OFFICIAL_WRITER_RETURN_RVA, 0x0000F7FA);
assert.equal(api.OFFICIAL_WRITER_RETURN_RVA, api.OFFICIAL_WRITER_CALLSITE_RVA + 6,
  'WriteFile return RVA must follow the verified six-byte indirect call');
assert.deepEqual(
  JSON.parse(JSON.stringify(api.EXE_TARGETS.map(({ name, va, rva, signature }) => ({ name, va, rva, signature })))),
  [
    { name: 'StartRcvVoice', va: 0x004E6D30, rva: 0x000E6D30, signature: '558bec565768600600006a00' },
    { name: 'ConnectCntl', va: 0x004D6DF0, rva: 0x000D6DF0, signature: '558bec81ecd0000000' },
    { name: 'PttWrapper', va: 0x0040DDB0, rva: 0x0000DDB0, signature: '558bec5356576a288bf9' },
  ],
);
assert.deepEqual(JSON.parse(JSON.stringify(api.MODE_GLOBALS)), [
  { name: 'b8', va: 0x02F1C7B8, rva: 0x02B1C7B8 },
  { name: 'bc', va: 0x02F1C7BC, rva: 0x02B1C7BC },
]);

const writerModuleBase = 0x50000000;
const writerReturnAddress = writerModuleBase + api.OFFICIAL_WRITER_RETURN_RVA;
assert.equal(api.matchesModuleRelativeAddress(writerReturnAddress, writerModuleBase, api.OFFICIAL_WRITER_RETURN_RVA), true);
assert.equal(api.matchesModuleRelativeAddress(writerModuleBase + 0x0000F829, writerModuleBase, api.OFFICIAL_WRITER_RETURN_RVA), false,
  'the second WriteFile wrapper return site F829 must remain outside coverage');
assert.equal(api.matchesModuleRelativeAddress(writerReturnAddress + 1, writerModuleBase, api.OFFICIAL_WRITER_RETURN_RVA), false);
assert.equal(api.matchesModuleRelativeAddress(writerReturnAddress, writerModuleBase + 0x10000, api.OFFICIAL_WRITER_RETURN_RVA), false,
  'the hook must use the loaded EXE base plus the verified RVA');

const writerTokens = api.createAnonymousHandleTokenRegistry(2);
const writerArgs = [];
writerArgs[0] = 'raw-handle-private-value';
Object.defineProperty(writerArgs, 1, {
  enumerable: true,
  get() { throw new Error('WriteFile payload pointer must not be inspected'); },
});
writerArgs[2] = 0x31;
const writerMetadata = api.officialWriterMetadata(
  writerReturnAddress, writerModuleBase, writerArgs, writerTokens,
);
assert.deepEqual(plain(writerMetadata), {
  handle_token: 'W1',
  requested_length_bytes: 0x31,
  payload_read: false,
});
assert.equal(writerMetadata.handle_token, writerTokens.tokenFor('raw-handle-private-value'),
  'the same handle must keep one anonymous token for this observer window');
assert.equal(writerTokens.tokenFor('another-private-handle'), 'W2');
assert.equal(writerTokens.tokenFor('third-private-handle'), null, 'handle token registry must stay bounded');
assert.equal(JSON.stringify(writerMetadata).includes('raw-handle-private-value'), false,
  'raw handle values must not enter emitted metadata');
assert.equal(api.officialWriterMetadata(
  writerModuleBase + 0x0000F829, writerModuleBase, writerArgs, writerTokens,
), null, 'F829 must not be promoted into the observed WriteFile return-site set');
assert.equal(api.win32CallSucceeded(1), true);
assert.equal(api.win32CallSucceeded(0), false);

const esp = { add(offset) { return { offset }; } };
assert.equal(api.entryStackArgument(esp, 1, (pointer) => pointer.offset), 8,
  'ConnectCntl row argument must map to entry ESP+8 as proven by the caller pushes');
assert.deepEqual(plain(api.pttArgumentsFromVerifiedCall([0, 0xffffffff], (value) => value)), { index: 0, value: -1 });
assert.equal(api.postThreadMessageFields([7, 0x714, 1, 2], (value) => value), null);
assert.deepEqual(plain(api.postThreadMessageFields([7, 0x715, 0, 0x1a], (value) => value)), {
  message: 0x715,
  wparam: 0,
  lparam: 0x1a,
});
assert.equal(api.isComPath('COM5'), true);
assert.equal(api.isComPath('\\\\.\\COM12'), true);
assert.equal(api.isComPath('C:\\temp\\voice.bin'), false);

function makeFrame(type, payload) {
  const length = payload.length.toString(16).padStart(4, '0').toUpperCase();
  const frame = [0x01, type.charCodeAt(0), ...Array.from(length, (character) => character.charCodeAt(0)), ...payload, 0x04, 0x41, 0x35];
  return Uint8Array.from(frame);
}

const tPayload = Uint8Array.from([
  0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, // allowed T body prefix, bytes 0..6
  0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, // allowed header control bytes, 7..14
  ...Array.from(Buffer.from('PRIVATE_CALLSIGN')),
  0x70, 0x71, 0x72, 0x73, 0x74, // synthetic AMBE-like payload
]);
const gPayload = Uint8Array.from(Buffer.from('G_PRIVATE_HEADER_AND_CALLSIGN'));
const sPayload = Uint8Array.from([0x53, 0x30]);
const frames = [
  makeFrame('T', tPayload),
  makeFrame('G', gPayload),
  makeFrame('S', sPayload),
  makeFrame('F', Uint8Array.from([0x46, 0x31])),
  makeFrame('$', Uint8Array.from([0x45, 0x4e, 0x44])),
];
const totalLength = frames.reduce((sum, frame) => sum + frame.length, 0);
const joined = new Uint8Array(totalLength);
const protectedOffsets = new Set();
let cursor = 0;
for (let index = 0; index < frames.length; index += 1) {
  const frame = frames[index];
  joined.set(frame, cursor);
  const payloadLength = frame.length - 9;
  const bodyStart = cursor + 6;
  for (let bodyOffset = 0; bodyOffset < payloadLength; bodyOffset += 1) {
    const allowedTControl = index === 0 && bodyOffset < 15;
    if (!allowedTControl) protectedOffsets.add(bodyStart + bodyOffset);
  }
  cursor += frame.length;
}

const readOffsets = [];
const events = [];
const parser = api.createEnvelopeParser();
const parsed = api.feedEnvelope(parser, 'tx', joined.length, (offset) => {
  assert.ok(Number.isInteger(offset) && offset >= 0 && offset < joined.length, 'out-of-range serial read');
  assert.ok(!protectedOffsets.has(offset), `observer read protected body byte at offset ${offset}`);
  readOffsets.push(offset);
  return joined[offset];
});
events.push(...parsed);

assert.equal(parser.disabled, false, 'valid synthetic record stream unexpectedly stopped');
assert.equal(events.length, 5);
assert.deepEqual(plain(events.map((event) => event.record_type)), ['T', 'G', 'S', 'F', '$']);
assert.deepEqual(plain(events.map((event) => event.payload_bytes)), [tPayload.length, gPayload.length, sPayload.length, 2, 3]);
assert.deepEqual(plain(events[0].t_control_prefix_u8), [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16]);
assert.deepEqual(plain(events[0].t_header_control_u8), [0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28]);
assert.equal(events[0].t_control_bytes_read, 15);
assert.equal(events[1].t_control_prefix_u8, undefined, 'G body must not be sampled');
assert.equal(events[0].declared_checksum_hex_unverified, 'A5');
assert.equal(events[0].checksum_verified, false, 'observer must not calculate checksum from payload');
assert.ok(!JSON.stringify(events).includes('PRIVATE_CALLSIGN'));
assert.ok(!JSON.stringify(events).includes('G_PRIVATE_HEADER'));
assert.equal(readOffsets.some((offset) => protectedOffsets.has(offset)), false);

const malformedParser = api.createEnvelopeParser();
const malformed = Uint8Array.from([0x01, 0x54, 0x30, 0x30, 0x30, 0x47, ...tPayload]);
const malformedReads = [];
const malformedEvents = api.feedEnvelope(malformedParser, 'tx', malformed.length, (offset) => {
  malformedReads.push(offset);
  return malformed[offset];
});
assert.equal(malformedParser.disabled, true);
assert.equal(malformedEvents[0].reason, 'invalid_length_field');
assert.deepEqual(malformedReads, [0, 1, 2, 3, 4, 5], 'malformed length must stop before body reads or resynchronization scanning');

const waveReads = [];
const waveMetadata = api.waveOutHeaderMetadata(0x20, (offset) => {
  waveReads.push(offset);
  if (offset === 0 || offset < 0 || offset >= 0x20) throw new Error('lpData or data bytes must not be read');
  return offset === 4 ? 0x400 : 0x22;
});
assert.deepEqual(plain(waveMetadata), { status: 'observed', buffer_length: 0x400, flags: 0x22 });
assert.deepEqual(waveReads, [4, 16], 'WaveOut observer may read only dwBufferLength and dwFlags');
assert.equal(api.waveOutHeaderMetadata(0x18, () => { throw new Error('unexpected header read'); }).status, 'unexpected_header_size');

assert.equal(context.Interceptor, undefined, 'offline fixture must not initialize Frida hooks');
assert.equal(context.NativeFunction, undefined, 'offline fixture must not call target native APIs');
process.stdout.write('R110 offline observer checks passed: corrected RVA mapping, exact WriteFile return-site filtering, anonymous handles, payload-read trap, caller-proven stack slots, T offsets 0..14 only, G/other bodies unread, checksum unverified, WaveOut metadata only\n');
