import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'packet.dart';

/// A received CHWP packet and the console it came from.
typedef ChwpDatagram = ({InternetAddress from, ChwpPacket packet});

/// UDP socket bound to the CHWP port.
///
/// Only one process per host can own port 4920, so the app cannot run on
/// the same machine as MagicQ.
class ChwpTransport {
  ChwpTransport._(this._socket) {
    _socket.broadcastEnabled = true;
    _socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = _socket.receive()) != null) {
          final packet = ChwpPacket.decode(d!.data);
          if (packet != null) _packets.add((from: d.address, packet: packet));
        }
      },
      onError: _packets.addError,
      onDone: _packets.close,
    );
  }

  static ChwpTransport? _shared;
  static Future<ChwpTransport>? _opening;
  static int _users = 0;

  /// Returns the process-wide socket on the CHWP port, opening it if needed.
  ///
  /// Discovery and connections must share one socket: MagicQ always replies
  /// to port 4920, and iOS/macOS refuse a second bind of the same UDP port.
  /// Pair every call with [release].
  static Future<ChwpTransport> acquire({int port = chwpPort}) async {
    _users++;
    try {
      return _shared ??= await (_opening ??= bind(port: port));
    } catch (_) {
      _users--;
      rethrow;
    } finally {
      _opening = null;
    }
  }

  /// Gives back a transport from [acquire]; the socket closes with the last user.
  void release() {
    if (!identical(this, _shared)) {
      close();
      return;
    }
    if (--_users > 0) return;
    _users = 0;
    _shared = null;
    close();
  }

  static Future<ChwpTransport> bind({int port = chwpPort}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    return ChwpTransport._(socket);
  }

  final RawDatagramSocket _socket;
  final StreamController<ChwpDatagram> _packets = StreamController.broadcast(sync: true);
  int _sequence = 0;

  Stream<ChwpDatagram> get packets => _packets.stream;

  void send(InternetAddress to, int type, [Uint8List? payload]) {
    final packet = ChwpPacket(type: type, sequence: _sequence++, payload: payload ?? Uint8List(0));
    _socket.send(packet.encode(), to, chwpPort);
  }

  void close() => _socket.close();
}
