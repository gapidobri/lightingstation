import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'cipher.dart';

/// UDP port used by MagicQ for the remote app protocol, in both directions.
///
/// MagicQ always replies to port 4920 on the sender's address, regardless
/// of the source port, so a client must bind this port locally.
const int chwpPort = 4920;

/// Size of the CHWP header; the payload starts at this offset.
const int chwpHeaderSize = 0x16;

const List<int> _magic = [0x43, 0x48, 0x57, 0x50]; // "CHWP"

/// Protocol version this client announces. MagicQ gates features on it
/// (e.g. v2.12+ gets the extended Execute item format), so keep it at the
/// version MagicQ 1.9.8.3 itself sends.
const int chwpVersionMajor = 2;
const int chwpVersionMinor = 0x19;

/// A decoded CHWP datagram.
///
/// Header layout (little endian):
/// ```
/// 0x00  char[4]  "CHWP"
/// 0x04  u8       version major
/// 0x05  u8       version minor
/// 0x06  u16      sequence number
/// 0x08  u8[10]   reserved (zero)
/// 0x12  u16      message type (replies have bit 15 set)
/// 0x14  u16      payload length
/// 0x16  ...      payload
/// ```
class ChwpPacket {
  ChwpPacket({
    required this.type,
    required this.payload,
    this.sequence = 0,
    this.versionMajor = chwpVersionMajor,
    this.versionMinor = chwpVersionMinor,
  });

  final int type;
  final int sequence;
  final int versionMajor;
  final int versionMinor;
  final Uint8List payload;

  /// Encodes and scrambles this packet, ready to send.
  Uint8List encode({Random? random}) {
    final plain = Uint8List(chwpHeaderSize + payload.length);
    final view = ByteData.sublistView(plain);
    plain.setRange(0, 4, _magic);
    plain[4] = versionMajor;
    plain[5] = versionMinor;
    view.setUint16(0x06, sequence & 0xffff, Endian.little);
    view.setUint16(0x12, type, Endian.little);
    view.setUint16(0x14, payload.length, Endian.little);
    plain.setRange(chwpHeaderSize, plain.length, payload);
    return scramble(plain, (random ?? Random()).nextInt(256));
  }

  /// Unscrambles and parses a datagram. Returns null if it is not CHWP.
  static ChwpPacket? decode(List<int> datagram) {
    if (datagram.length < chwpHeaderSize) return null;
    final plain = unscramble(datagram);
    for (var i = 0; i < 4; i++) {
      if (plain[i] != _magic[i]) return null;
    }
    final view = ByteData.sublistView(plain);
    final length = view.getUint16(0x14, Endian.little);
    final end = min(chwpHeaderSize + length, plain.length);
    return ChwpPacket(
      type: view.getUint16(0x12, Endian.little),
      sequence: view.getUint16(0x06, Endian.little),
      versionMajor: plain[4],
      versionMinor: plain[5],
      payload: Uint8List.sublistView(plain, chwpHeaderSize, end),
    );
  }
}

/// Little-endian cursor over a payload, tolerant of truncated data.
class PayloadReader {
  PayloadReader(this.bytes, [this.offset = 0]) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _view;
  int offset;

  int get remaining => bytes.length - offset;

  int u8() => bytes[offset++];

  int u16() {
    final v = _view.getUint16(offset, Endian.little);
    offset += 2;
    return v;
  }

  int u32() {
    final v = _view.getUint32(offset, Endian.little);
    offset += 4;
    return v;
  }

  /// Reads a NUL-terminated string.
  String cString() {
    var end = offset;
    while (end < bytes.length && bytes[end] != 0) {
      end++;
    }
    final s = latin1.decode(bytes.sublist(offset, end));
    offset = min(end + 1, bytes.length);
    return s;
  }

  /// Reads a fixed-size, NUL-padded string field.
  String fixedString(int size) {
    final end = min(offset + size, bytes.length);
    var stop = offset;
    while (stop < end && bytes[stop] != 0) {
      stop++;
    }
    final s = latin1.decode(bytes.sublist(offset, stop));
    offset = end;
    return s;
  }

  /// Reads [length] bytes as a string (no terminator).
  String string(int length) {
    final end = min(offset + length, bytes.length);
    final s = latin1.decode(bytes.sublist(offset, end));
    offset = end;
    return s;
  }
}

/// Little-endian payload builder.
class PayloadWriter {
  final BytesBuilder _b = BytesBuilder();

  void u16(int v) => _b.add([v & 0xff, (v >> 8) & 0xff]);

  void u32(int v) => _b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

  void cString(String s) => _b
    ..add(latin1.encode(s))
    ..addByte(0);

  Uint8List toBytes() => _b.toBytes();
}
