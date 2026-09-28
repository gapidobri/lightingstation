import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// TCP port of MagicQ's multi-console network ("comms").
const int chmqCommsPort = 4911;

/// UDP port on which MagicQ accepts requests to open a comms link.
const int chmqRequestPort = 4910;

/// Header version MagicQ 1.9.8.3 writes, and the one this client announces.
/// MagicQ remaps window IDs for peers below version 8.
const int chmqVersion = 0x1b;

const int chmqHeaderSize = 10;

const List<int> _magic = [0x43, 0x48, 0x4d, 0x51]; // "CHMQ"

/// CHMQ message types used here.
abstract final class ChmqType {
  /// Keepalive. A hello with flag bit 0 clear asks the peer to answer.
  static const hello = 0x01;

  /// Link flags (u16 at 0x0a) and a monitor (u16 at 0x0c). Unless the
  /// flags have [ChmqLinkFlags.inputOnly] or [ChmqLinkFlags.noInput], each
  /// one makes the console send a full dump of its screen (`FUN_100481b30`):
  /// status, windows, and the playback strips. MagicQ's own controller
  /// sends one every ~80 ms.
  static const linkFlags = 0x06;

  /// Raw console input (keys, buttons, encoders, mouse), XOR-masked.
  static const input = 0x10;

  /// Text of one console widget (`FUN_10047ffe0`): soft keys, and the
  /// playback strips above the on-screen faders. See [ChmqPlaybackStrip].
  static const widget = 0x0e;

  /// Console status (`FUN_10047f480`), including the selected window. See
  /// [ChmqStatus].
  static const status = 0x0f;
}

/// Link flags a peer announces (UDP request, and message type 6).
abstract final class ChmqLinkFlags {
  /// Don't send server lists or window streams to this peer. This client
  /// only sends input, so it announces this.
  static const inputOnly = 0x10;

  /// MagicQ never transmits on a link with this flag, and doesn't even open
  /// it from a UDP request. Never set.
  static const silent = 0x20;

  /// MagicQ ignores type 0x10 input from a link with this flag.
  static const noInput = 0x400;

  /// What MagicQ's own controller announces in [ChmqType.linkFlags]: stream
  /// the screen. Bit 0 also includes windows that aren't on a monitor;
  /// bit 2 is unknown.
  static const screenSync = 0x05;
}

/// A [ChmqType.linkFlags] message. [monitor] picks which of the console's
/// monitors to mirror (0 as MagicQ's controller sends).
Uint8List chmqLinkFlags(int flags, {int monitor = 0}) {
  final body = Uint8List(4);
  ByteData.sublistView(body)
    ..setUint16(0, flags, Endian.little)
    ..setUint16(2, monitor, Endian.little);
  return encodeChmq(ChmqType.linkFlags, body);
}

/// Subtypes of [ChmqType.input] (`FUN_100482080`).
abstract final class ChmqInput {
  /// Keyboard key; MagicQ first selects (and opens) the target window.
  static const key = 0;

  /// A physical console button by board index (`FUN_1004fad20`). No window
  /// is selected, so this is what the playback buttons use.
  static const button = 4;
}

/// Frames a CHMQ message: `CHMQ`, u8 version, u8 length bits 16..23, u16
/// length (header included), u16 type, then [body] from offset 10.
Uint8List encodeChmq(int type, List<int> body) {
  final length = chmqHeaderSize + body.length;
  final out = Uint8List(length);
  final view = ByteData.sublistView(out);
  out.setRange(0, 4, _magic);
  out[4] = chmqVersion;
  out[5] = (length >> 16) & 0xff;
  view.setUint16(6, length & 0xffff, Endian.little);
  view.setUint16(8, type, Endian.little);
  out.setRange(chmqHeaderSize, length, body);
  return out;
}

/// The UDP datagram (to [chmqRequestPort]) that asks MagicQ to open a comms
/// link back to the sender's [chmqCommsPort] (`FUN_100161e90` →
/// `FUN_1001612b0`). [flags] become the console's flags for that link.
Uint8List chmqLinkRequest({int flags = ChmqLinkFlags.inputOnly, String name = ''}) {
  final body = Uint8List(28 - chmqHeaderSize);
  ByteData.sublistView(body).setUint16(0, flags, Endian.little);
  final nameBytes = ascii.encode(name.replaceAll(RegExp(r'[^\x20-\x7e]'), ''));
  body.setRange(2, 2 + min(nameBytes.length, 15), nameBytes);
  return encodeChmq(0, body);
}

/// Keepalive. MagicQ drops a link that sends no hello for about a second,
/// and any link older than ~166 ms when another request comes in.
Uint8List chmqHello({bool wantReply = true}) {
  final body = Uint8List(28 - chmqHeaderSize);
  body[0] = wantReply ? 0 : 1;
  return encodeChmq(ChmqType.hello, body);
}

/// MagicQ's XOR key for the input payload (`DAT_101e2d760`). Byte `i`
/// masks packet offset `0x1f - i`.
const List<int> _inputKey = [
  0x69, 0x1c, 0x38, 0xe9, 0x87, 0xcb, 0x37, 0x19, 0x38, 0xa3, //
  0x0b, 0x57, 0xab, 0x33, 0x9e, 0x29, 0x52, 0x19, 0xf8, 0x27,
];

/// Packet offset holding bit `j` (at bit position `j % 8`) of value A and
/// value B. Every other bit of those bytes is random filler.
const List<int> _aBytes = [
  0x19, 0x16, 0x0e, 0x1d, 0x1a, 0x1c, 0x10, 0x1b, //
  0x18, 0x15, 0x17, 0x13, 0x0d, 0x1e, 0x0c, 0x1f,
];
const List<int> _bBytes = [
  0x1b, 0x19, 0x16, 0x0e, 0x1d, 0x1a, 0x1c, 0x10, //
  0x1f, 0x18, 0x15, 0x17, 0x13, 0x0d, 0x1e, 0x0c,
];

/// One decoded [ChmqType.input] message.
class ChmqInputMessage {
  const ChmqInputMessage({required this.window, required this.subtype, this.a = 0, this.b = 0, this.mods = 0});

  /// Target window ID (must be 1..0x2e3 for MagicQ to accept it).
  final int window;
  final int subtype;

  /// Subtype arguments; for [ChmqInput.button], [a] is the board button
  /// index and [b] is 1 while pressed.
  final int a;
  final int b;
  final int mods;

  @override
  bool operator ==(Object other) =>
      other is ChmqInputMessage &&
      other.window == window &&
      other.subtype == subtype &&
      other.a == a &&
      other.b == b &&
      other.mods == mods;

  @override
  int get hashCode => Object.hash(window, subtype, a, b, mods);

  @override
  String toString() => 'ChmqInputMessage(window: $window, subtype: $subtype, a: $a, b: $b, mods: $mods)';
}

/// Encodes an input message as MagicQ's controller does (`FUN_100481180`):
/// 32 bytes, u16 window at 0x0a, then 20 masked bytes.
Uint8List encodeChmqInput(ChmqInputMessage m, {Random? random}) {
  final rnd = random ?? Random();
  final plain = List<int>.generate(0x20, (i) => i >= 0x0c ? rnd.nextInt(256) : 0);
  plain[0x0f] = m.subtype & 0xff;
  plain[0x14] = (m.subtype >> 8) & 0xff;
  plain[0x11] = m.mods & 0xff;
  plain[0x12] = (m.mods >> 8) & 0xff;
  for (var j = 0; j < 16; j++) {
    final mask = 1 << (j % 8);
    plain[_aBytes[j]] = (plain[_aBytes[j]] & ~mask) | ((m.a >> j) & 1) * mask;
    plain[_bBytes[j]] = (plain[_bBytes[j]] & ~mask) | ((m.b >> j) & 1) * mask;
  }
  final body = Uint8List(0x20 - chmqHeaderSize);
  ByteData.sublistView(body).setUint16(0, m.window, Endian.little);
  for (var off = 0x0c; off < 0x20; off++) {
    body[off - chmqHeaderSize] = plain[off] ^ _inputKey[0x1f - off];
  }
  return encodeChmq(ChmqType.input, body);
}

/// Decodes an input message the way MagicQ does (`FUN_100482080`). Returns
/// null if [frame] is not a complete one.
ChmqInputMessage? decodeChmqInput(List<int> frame) {
  final f = parseChmqFrame(frame);
  if (f == null || f.type != ChmqType.input || frame.length < 0x20) return null;
  int p(int off) => frame[off] ^ _inputKey[0x1f - off];
  var a = 0, b = 0;
  for (var j = 0; j < 16; j++) {
    a |= ((p(_aBytes[j]) >> (j % 8)) & 1) << j;
    b |= ((p(_bBytes[j]) >> (j % 8)) & 1) << j;
  }
  return ChmqInputMessage(
    window: frame[0x0a] | frame[0x0b] << 8,
    subtype: p(0x14) << 8 | p(0x0f),
    a: a,
    b: b,
    mods: p(0x12) << 8 | p(0x11),
  );
}

/// A console button press or release, [index] as in [ChmqButtons].
Uint8List chmqButton(int index, {required bool pressed, Random? random}) => encodeChmqInput(
  ChmqInputMessage(window: 1, subtype: ChmqInput.button, a: index, b: pressed ? 1 : 0),
  random: random,
);

/// Board button indices of the playback keys (table at `0x101e365d0`, which
/// maps them to keycodes 0x100 + index). Playbacks are 1-based.
abstract final class ChmqButtons {
  static int flash(int playback) => _check(playback) - 1;
  static int pause(int playback) => _check(playback) + 9;
  static int go(int playback) => _check(playback) + 19;
  static int select(int playback) => _check(playback) + 38;

  static int _check(int playback) {
    RangeError.checkValueInInterval(playback, 1, 10, 'playback');
    return playback;
  }
}

/// A CHMQ frame header.
class ChmqFrame {
  const ChmqFrame(this.type, this.length);

  final int type;

  /// Total frame length, header included.
  final int length;
}

/// Reads the header at the start of [bytes], or null if it is incomplete or
/// not CHMQ. Mirrors `FUN_10016f350`: from version 7 the length has a high
/// byte at offset 5.
ChmqFrame? parseChmqFrame(List<int> bytes) {
  if (bytes.length < chmqHeaderSize) return null;
  for (var i = 0; i < 4; i++) {
    if (bytes[i] != _magic[i]) return null;
  }
  var length = bytes[6] | bytes[7] << 8;
  if (bytes[4] > 6) length |= bytes[5] << 16;
  if (length < chmqHeaderSize) return null;
  return ChmqFrame(bytes[8] | bytes[9] << 8, length);
}
