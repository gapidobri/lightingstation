import 'dart:typed_data';

import 'packet.dart';

/// CHWP message types. Console replies use `type | 0x8000`.
abstract final class ChwpType {
  /// Register with the console (optionally with user credentials).
  static const connect = 0x01;

  /// Console key press/release (index into MagicQ's remote key table).
  static const key = 0x02;

  /// Press/release an item on the client's current Execute page.
  static const executeButton = 0x04;

  /// Request an Execute page. Reply: [executePageReply].
  static const executePage = 0x06;

  /// Read a MagicQ window's header and items (read-only, no window is
  /// selected). Replies: [windowReply], [windowItemsReply].
  static const window = 0x08;

  /// Select a MagicQ window on the console (flag bit 0), opening it, or an
  /// item in it. This changes the console's screen.
  static const windowSelect = 0x0c;

  /// Set the level of a fader item on the client's current Execute page.
  static const executeFader = 0x0e;

  /// Console info query; answered even for unregistered clients, so it
  /// doubles as discovery when broadcast. Reply: [infoReply].
  static const info = 0x14;

  static const connectReply = 0x8001;
  static const statusReply = 0x8002;
  static const executePageReply = 0x8003;
  static const windowReply = 0x8006;
  static const windowItemsReply = 0x8007;

  /// Column headers of a table window, after [windowReply].
  static const windowColumnsReply = 0x8008;
  static const infoReply = 0x800d;
}

/// Builders for client → console payloads.
abstract final class ChwpRequests {
  /// Credentials are only checked when MagicQ has users configured.
  static Uint8List connect({String? user, String? password}) {
    final w = PayloadWriter()..u32(0);
    if (user != null && user.isNotEmpty) {
      w
        ..cString(password ?? '')
        ..cString(user);
    }
    return w.toBytes();
  }

  static Uint8List info() => Uint8List(0);

  /// Selects [page] (1-based) and requests its contents. With [page] null,
  /// requests the page this client already has selected.
  ///
  /// [colourMode] asks MagicQ to report each item's colour instead of a
  /// plain on/off state.
  static Uint8List executePage({int? page, bool colourMode = true}) =>
      (PayloadWriter()
            ..u16(page ?? 1)
            ..u16(colourMode ? 1 : 0)
            ..u16(page == null ? 0 : 1))
          .toBytes();

  /// Requests [window]'s header and [count] items from [first]
  /// (`FUN_100543870`; MagicQ only reads, and allows it in demo mode).
  static Uint8List window(int window, {int first = 0, int count = 0}) =>
      (PayloadWriter()
            ..u16(0)
            ..u16(window)
            ..u16(first)
            ..u16(count))
          .toBytes();

  /// [index] is row-major across the page grid.
  static Uint8List executeButton(int index, {required bool pressed}) =>
      (PayloadWriter()
            ..u16(index)
            ..u16(pressed ? 1 : 0))
          .toBytes();

  /// [level] is 0..255.
  static Uint8List executeFader(int index, int level) =>
      (PayloadWriter()
            ..u16(index)
            ..u16(0)
            ..u16(level.clamp(0, 255)))
          .toBytes();

  static Uint8List key(int keyIndex, {required bool pressed}) =>
      (PayloadWriter()
            ..u16(keyIndex)
            ..u16(pressed ? 1 : 0))
          .toBytes();
}

/// Result of a [ChwpType.connect] request.
enum ConnectStatus {
  ok,
  loggedIn,
  loggedInAdmin,
  unknownUser,
  wrongPassword,
  unknown;

  static ConnectStatus fromCode(int code) => switch (code) {
    0 => ok,
    1 => loggedIn,
    2 => loggedInAdmin,
    3 => unknownUser,
    4 => wrongPassword,
    _ => unknown,
  };

  bool get accepted => this == ok || this == loggedIn || this == loggedInAdmin;
}

class ConnectReply {
  ConnectReply(this.status, this.consoleName);

  final ConnectStatus status;
  final String consoleName;

  static ConnectReply parse(Uint8List payload) {
    final r = PayloadReader(payload);
    final status = ConnectStatus.fromCode(r.u32());
    return ConnectReply(status, r.remaining > 0 ? r.fixedString(16) : '');
  }
}

/// Periodic console status (message line and command line).
class ConsoleStatus {
  ConsoleStatus({required this.flags, required this.shortText, required this.lines});

  final int flags;
  final String shortText;

  /// Usually two lines: the status/message line and the command line.
  final List<String> lines;

  static ConsoleStatus parse(Uint8List payload) {
    final r = PayloadReader(payload);
    final flags = r.u32();
    final shortText = r.fixedString(12);
    final text = r.remaining > 0 ? r.fixedString(99) : '';
    return ConsoleStatus(flags: flags, shortText: shortText, lines: text.split('\n'));
  }
}

/// Reply to [ChwpType.info].
class ConsoleInfo {
  ConsoleInfo({
    required this.address,
    required this.version,
    required this.showName,
    required this.host,
    required this.consoleName,
  });

  final String address;
  final String version;
  final String showName;
  final String host;
  final String consoleName;

  String get displayName => consoleName.isNotEmpty ? consoleName : (host.isNotEmpty ? host : address);

  static ConsoleInfo parse(String address, Uint8List payload) {
    final r = PayloadReader(payload)..offset = 0x0a;
    final versionLen = r.u16();
    r.u16();
    final showLen = r.u16();
    final hostLen = r.u16();
    final nameLen = r.u16();
    return ConsoleInfo(
      address: address,
      version: r.string(versionLen),
      showName: r.string(showLen),
      host: r.string(hostLen),
      consoleName: r.string(nameLen),
    );
  }

  @override
  String toString() => 'MagicQ $version "$displayName" at $address';
}
