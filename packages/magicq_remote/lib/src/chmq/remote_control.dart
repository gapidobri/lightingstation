import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'chmq.dart';
import 'screen.dart';

/// State of a [MagicQRemoteControl] link.
enum RemoteLinkState {
  /// Asking the console to connect back; it hasn't yet.
  waiting,

  /// The console is connected; button presses are delivered.
  linked,
}

/// Presses the console's own playback buttons over MagicQ's multi-console
/// network, the path "Remote control another MagicQ" uses.
///
/// Unlike CREP, these go through MagicQ's button handling, so console
/// settings such as speed-master tap tempo and "Go uses Exec Grid" apply.
/// Button input selects no window on the console.
///
/// The console opens the link: this client listens on TCP
/// [chmqCommsPort] and sends a UDP request to the console's
/// [chmqRequestPort], and MagicQ connects back. MagicQ needs "Enable remote
/// control" and a licence unlocked for remote control; without the unlock
/// it shows "Remote request - not unlocked" and ignores the input.
///
/// With [screenSync], the link also mirrors the console's screen as MagicQ's
/// own controller does: [playbackStrips] (cue text, speed masters) and the
/// [selectedWindow]. That costs roughly 25 KB per refresh.
class MagicQRemoteControl {
  MagicQRemoteControl._(this.console, this._server, this._udp, this._requestPort, this.name, this.screenSync);

  /// Starts listening and asks [console] to connect. Throws a
  /// [SocketException] if [commsPort] can't be bound (e.g. another app, or
  /// MagicQ itself on this machine, holds it).
  static Future<MagicQRemoteControl> start(
    InternetAddress console, {
    String name = 'Lighting Station',
    int commsPort = chmqCommsPort,
    int requestPort = chmqRequestPort,
    bool screenSync = false,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, commsPort);
    RawDatagramSocket udp;
    try {
      udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {
      await server.close();
      rethrow;
    }
    final remote = MagicQRemoteControl._(console, server, udp, requestPort, name, screenSync);
    remote._start();
    return remote;
  }

  /// Hello interval. MagicQ closes a link whose last hello is older than
  /// ~166 ms whenever another link request arrives, and any link after
  /// ~1 s without one.
  static const helloInterval = Duration(milliseconds: 50);

  /// How often to repeat the link request while waiting.
  static const requestInterval = Duration(seconds: 1);

  /// How often to ask for a screen dump with [screenSync]. MagicQ's own
  /// controller asks every ~80 ms; each dump is about 25 KB.
  static const syncInterval = Duration(milliseconds: 250);

  final InternetAddress console;
  final String name;

  /// Whether the link mirrors the console's screen.
  final bool screenSync;
  final ServerSocket _server;
  final RawDatagramSocket _udp;
  final int _requestPort;
  final _random = Random();
  final _states = StreamController<RemoteLinkState>.broadcast();
  final _strips = StreamController<ChmqPlaybackStrip>.broadcast();
  final _statuses = StreamController<ChmqStatus>.broadcast();

  Socket? _link;
  Timer? _requestTimer;
  Timer? _helloTimer;
  Timer? _syncTimer;
  int? _selectedWindow;
  StreamSubscription<Socket>? _accepts;
  bool _closed = false;

  // Buttons currently held, so they can be released if the link drops.
  final Set<int> _held = {};

  RemoteLinkState get state => _link == null ? RemoteLinkState.waiting : RemoteLinkState.linked;
  bool get isLinked => _link != null;
  Stream<RemoteLinkState> get states => _states.stream;

  /// Playback strips, one per on-screen playback, on every refresh (with
  /// [screenSync]).
  Stream<ChmqPlaybackStrip> get playbackStrips => _strips.stream;

  /// Console status on every refresh (with [screenSync]).
  Stream<ChmqStatus> get statuses => _statuses.stream;

  /// The console's selected window as last reported (with [screenSync]), or
  /// null when unknown or none.
  int? get selectedWindow => _selectedWindow;

  void _start() {
    _accepts = _server.listen(_onConnection);
    _sendRequest();
    _requestTimer = Timer.periodic(requestInterval, (_) {
      if (_link == null) _sendRequest();
    });
  }

  void _sendRequest() {
    final flags = screenSync ? ChmqLinkFlags.screenSync : ChmqLinkFlags.inputOnly;
    _udp.send(chmqLinkRequest(flags: flags, name: name), console, _requestPort);
  }

  void _onConnection(Socket socket) {
    if (socket.remoteAddress != console || _link != null || _closed) {
      socket.destroy();
      return;
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _link = socket;
    _states.add(RemoteLinkState.linked);
    _sendHello();
    _helloTimer = Timer.periodic(helloInterval, (_) => _sendHello());
    if (screenSync) {
      _requestScreen();
      _syncTimer = Timer.periodic(syncInterval, (_) => _requestScreen());
    }
    // Without screen sync MagicQ only sends hellos; the link just needs to
    // stay drained and to notice when it closes.
    final reader = screenSync ? ChmqFrameReader() : null;
    socket.listen(
      (data) {
        if (reader != null) reader.add(data).forEach(_onFrame);
      },
      onError: (_) => _drop(socket),
      onDone: () => _drop(socket),
      cancelOnError: true,
    );
  }

  void _requestScreen() => _write(chmqLinkFlags(ChmqLinkFlags.screenSync));

  void _onFrame(Uint8List frame) {
    switch (parseChmqFrame(frame)?.type) {
      case ChmqType.widget:
        final strip = ChmqPlaybackStrip.parse(frame);
        if (strip != null) _strips.add(strip);
      case ChmqType.status:
        final status = ChmqStatus.parse(frame);
        if (status == null) return;
        _selectedWindow = status.selectedWindow;
        _statuses.add(status);
    }
  }

  void _drop(Socket socket) {
    if (_link != socket) return;
    _link = null;
    _helloTimer?.cancel();
    _helloTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _selectedWindow = null;
    _held.clear();
    socket.destroy();
    if (!_closed) {
      _states.add(RemoteLinkState.waiting);
      _sendRequest();
    }
  }

  void _sendHello() => _write(chmqHello());

  bool _write(Uint8List frame) {
    final link = _link;
    if (link == null) return false;
    try {
      link.add(frame);
      return true;
    } catch (_) {
      _drop(link);
      return false;
    }
  }

  /// Presses or releases the console button at board [index] (see
  /// [ChmqButtons]). Returns false if the link is down.
  bool setButton(int index, {required bool pressed}) {
    if (pressed) {
      _held.add(index);
    } else {
      _held.remove(index);
    }
    return _write(chmqButton(index, pressed: pressed, random: _random));
  }

  bool flash(int playback, {required bool down}) => setButton(ChmqButtons.flash(playback), pressed: down);
  bool go(int playback, {required bool down}) => setButton(ChmqButtons.go(playback), pressed: down);
  bool pause(int playback, {required bool down}) => setButton(ChmqButtons.pause(playback), pressed: down);

  Future<void> close() async {
    if (_closed) return;
    // Don't leave a flash held on the console.
    for (final index in _held.toList()) {
      setButton(index, pressed: false);
    }
    _closed = true;
    _requestTimer?.cancel();
    _helloTimer?.cancel();
    _syncTimer?.cancel();
    await _accepts?.cancel();
    final link = _link;
    _link = null;
    if (link != null) {
      await link.flush().catchError((_) {});
      link.destroy();
    }
    _udp.close();
    await _server.close();
    await _states.close();
    await _strips.close();
    await _statuses.close();
  }
}
