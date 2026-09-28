import 'dart:async';
import 'dart:io';

import 'chwp/execute.dart';
import 'chwp/messages.dart';
import 'chwp/packet.dart';
import 'chwp/transport.dart';
import 'chwp/window.dart';
import 'crep/crep.dart';

/// True for "address already in use" on iOS/macOS (48), Linux/Android (98)
/// and Windows (10048).
bool isAddressInUse(SocketException e) => const {48, 98, 10048}.contains(e.osError?.errorCode);

class MagicQConnectException implements Exception {
  MagicQConnectException(this.message);

  final String message;

  @override
  String toString() => 'MagicQConnectException: $message';
}

/// A live remote session with one MagicQ console.
///
/// Execute pages and console status come over CHWP (the MagicQ Remote app
/// protocol). CHWP has no playback fader messages, so playback levels and
/// buttons go over CREP, which must be enabled on the console separately.
/// With "ChamSys Rem (tx + rx)", MagicQ also broadcasts playback state back.
/// Playback names and current cues are read from MagicQ's Playbacks window
/// over CHWP, which needs no CREP setup.
class MagicQClient {
  MagicQClient._(this.console, this._transport, this._crep, this.crepPort, {required this.receivesPlaybackState}) {
    _sub = _transport.packets.where((d) => d.from == console).listen(_onDatagram);
    _crep.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = _crep.receive()) != null) {
        if (d!.address == console) _onCrep(decodeCrep(d.data));
      }
    });
  }

  /// Registers with the console at [host].
  ///
  /// [user] and [password] are only needed when MagicQ has users set up.
  static Future<MagicQClient> connect(
    String host, {
    String? user,
    String? password,
    int crepPort = defaultCrepPort,
    Duration timeout = const Duration(seconds: 3),
    Duration pollInterval = const Duration(milliseconds: 250),
  }) async {
    final address = (await InternetAddress.lookup(host, type: InternetAddressType.IPv4)).first;
    final ChwpTransport transport;
    try {
      transport = await ChwpTransport.acquire();
    } on SocketException catch (e) {
      if (!isAddressInUse(e)) rethrow;
      throw MagicQConnectException(
        'Port $chwpPort is in use by another app on this device, most likely '
        'the MagicQ Remote app. Force-quit it and try again. (During '
        'development, a hot restart can also leave the port open; fully '
        'restart the app.)',
      );
    }
    // MagicQ broadcasts playback state to the CREP port. If another app
    // holds it, fall back to a send-only socket.
    var receivesPlaybackState = true;
    RawDatagramSocket crep;
    try {
      crep = await RawDatagramSocket.bind(InternetAddress.anyIPv4, crepPort, reuseAddress: true);
    } on SocketException {
      crep = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      receivesPlaybackState = false;
    }
    final client = MagicQClient._(address, transport, crep, crepPort, receivesPlaybackState: receivesPlaybackState)
      .._user = user
      .._password = password;
    try {
      final reply = await client._handshake(timeout);
      if (!reply.status.accepted) {
        throw MagicQConnectException('Login rejected: ${reply.status.name}');
      }
      client.consoleName = reply.consoleName;
    } catch (_) {
      client.close();
      rethrow;
    }
    client._startPolling(pollInterval);
    return client;
  }

  final InternetAddress console;
  final ChwpTransport _transport;
  final RawDatagramSocket _crep;
  final int crepPort;

  /// False when the CREP port could not be bound, so feedback is missing.
  final bool receivesPlaybackState;
  late final StreamSubscription<ChwpDatagram> _sub;
  String? _user;
  String? _password;

  String consoleName = '';

  final _connectReplies = StreamController<ConnectReply>.broadcast(sync: true);
  final _pages = StreamController<ExecutePage>.broadcast();
  final _status = StreamController<ConsoleStatus>.broadcast();
  final _online = StreamController<bool>.broadcast();
  final _playbacks = StreamController<PlaybackState>.broadcast();
  final _playbackPages = StreamController<int>.broadcast();
  final _playbackInfo = StreamController<PlaybackInfo>.broadcast();
  final _windowHeaders = StreamController<WindowInfo>.broadcast();
  final _windowItems = StreamController<WindowItemsChunk>.broadcast();
  final _windowColumns = StreamController<WindowColumns>.broadcast();
  final _assembler = ExecutePageAssembler();
  final _playbackWindow = PlaybackWindowReader();

  Timer? _pollTimer;
  Timer? _flushTimer;
  DateTime _lastReceived = DateTime.now();
  bool _isOnline = true;
  int _crepSequence = 0;
  ExecutePage? _executePage;

  // Latest unsent value per fader, flushed at a fixed rate.
  final Map<int, int> _pendingExecuteFaders = {};

  Stream<ExecutePage> get executePages => _pages.stream;
  Stream<ConsoleStatus> get status => _status.stream;

  /// Emits false when the console stops answering, true when it is back.
  Stream<bool> get online => _online.stream;
  bool get isOnline => _isOnline;

  ExecutePage? get executePage => _executePage;

  /// Playback changes reported by MagicQ over CREP (tx mode only).
  Stream<PlaybackState> get playbackStates => _playbacks.stream;

  /// Playback page changes reported by MagicQ over CREP (tx mode only).
  Stream<int> get playbackPages => _playbackPages.stream;

  /// Playback names and current cues, polled from the Playbacks window.
  Stream<PlaybackInfo> get playbackInfo => _playbackInfo.stream;

  /// Raw window replies, for [requestWindow] and the Playbacks window poll.
  Stream<WindowInfo> get windowHeaders => _windowHeaders.stream;
  Stream<WindowItemsChunk> get windowItems => _windowItems.stream;
  Stream<WindowColumns> get windowColumns => _windowColumns.stream;

  /// The last console status, or null before the first one.
  ConsoleStatus? lastStatus;

  Future<ConnectReply> _handshake(Duration timeout) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      _sendConnect();
      try {
        return await _connectReplies.stream.first.timeout(timeout ~/ 3);
      } on TimeoutException {
        continue;
      }
    }
    throw MagicQConnectException('No reply from ${console.address}. Is "Enable remote app" on?');
  }

  void _sendConnect() =>
      _transport.send(console, ChwpType.connect, ChwpRequests.connect(user: _user, password: _password));

  void _startPolling(Duration interval) {
    requestExecutePage();
    requestPlaybackWindow();
    var tick = 0;
    _pollTimer = Timer.periodic(interval, (_) {
      final silent = DateTime.now().difference(_lastReceived);
      if (silent > interval * 8) {
        _setOnline(false);
        _sendConnect();
      }
      requestExecutePage();
      // Names change rarely, and CREP feedback reports cues at once, so
      // every other tick is enough.
      if ((tick++).isOdd) requestPlaybackWindow();
    });
  }

  /// Items to read from the Playbacks window: its standard view has one
  /// per playback (plus wing and header cells), the status view 12 columns
  /// by up to 17 rows.
  static const _playbackWindowItems = 256;

  /// Requests the Playbacks window's items, reported on [playbackInfo].
  void requestPlaybackWindow() => requestWindow(MagicQWindow.playbacks, count: _playbackWindowItems);

  /// Requests [window]'s header and [count] items, reported on
  /// [windowHeaders] and [windowItems]. Read-only.
  void requestWindow(int window, {int first = 0, int count = 256}) =>
      _transport.send(console, ChwpType.window, ChwpRequests.window(window, first: first, count: count));

  /// Reads the steps of the stack MagicQ's Cue Stack window shows, which
  /// is the console's selected playback unless the window is locked.
  /// Completes once replies have been quiet for [settle], or throws a
  /// [TimeoutException] after [timeout] without a usable reply.
  ///
  /// [onProgress] gets the steps read so far each time items arrive, so a
  /// caller can show them before the quiet period ends.
  Future<({String title, List<CueStep> steps})> readCueStack({
    Duration settle = const Duration(milliseconds: 200),
    Duration timeout = const Duration(seconds: 2),
    void Function(({String title, List<CueStep> steps}) partial)? onProgress,
  }) async {
    final reader = CueStackReader();
    final done = Completer<void>();
    Timer? quiet;
    void heard() {
      quiet?.cancel();
      quiet = Timer(settle, () {
        if (!done.isCompleted) done.complete();
      });
    }

    final subs = [
      _windowHeaders.stream.listen((h) {
        reader.header(h);
        if (h.window == MagicQWindow.cueStack) heard();
      }),
      _windowColumns.stream.listen((c) {
        reader.columns(c);
        if (c.window == MagicQWindow.cueStack) heard();
      }),
      _windowItems.stream.listen((chunk) {
        reader.add(chunk);
        if (chunk.window != MagicQWindow.cueStack) return;
        heard();
        final steps = onProgress == null ? null : reader.steps;
        if (steps != null && steps.isNotEmpty) onProgress!((title: reader.title, steps: steps));
      }),
    ];
    try {
      requestWindow(MagicQWindow.cueStack, count: _cueStackItems);
      await done.future.timeout(timeout);
    } finally {
      quiet?.cancel();
      for (final s in subs) {
        s.cancel();
      }
    }
    final steps = reader.steps;
    if (steps == null) {
      throw MagicQConnectException('The Cue Stack window has no "Cue id" column; switch it back to its default view.');
    }
    return (title: reader.title, steps: steps);
  }

  /// Items to read from the Cue Stack window; MagicQ stops at the window's
  /// own item count.
  static const _cueStackItems = 0x4000;

  /// Asks for the Cue Stack window's header every [interval] until its
  /// title passes [accept], and returns that title. Throws a
  /// [TimeoutException] after [timeout]. Read-only.
  ///
  /// MagicQ takes ~0.8-0.9 s to switch the window after a Select press
  /// (measured live), so wait for the new title before [readCueStack].
  Future<String> waitForCueStackTitle(
    bool Function(String title) accept, {
    Duration interval = const Duration(milliseconds: 50),
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final done = Completer<String>();
    final sub = _windowHeaders.stream.where((h) => h.window == MagicQWindow.cueStack).listen((h) {
      if (!done.isCompleted && accept(h.title)) done.complete(h.title);
    });
    void ask() => requestWindow(MagicQWindow.cueStack, count: 1);
    final poll = Timer.periodic(interval, (_) => ask());
    try {
      ask();
      return await done.future.timeout(timeout);
    } finally {
      poll.cancel();
      await sub.cancel();
    }
  }

  /// Asks MagicQ for the level and active state of playbacks
  /// [first]..[last] (1-based), reported on [playbackStates]. Needs a CREP
  /// tx mode, like the rest of the feedback.
  void requestPlaybackStates(int first, int last) => sendCrep(CrepCommand.queryPlaybacks(first, last));

  void _setOnline(bool value) {
    if (_isOnline == value) return;
    _isOnline = value;
    _online.add(value);
  }

  void _onDatagram(ChwpDatagram d) {
    _lastReceived = DateTime.now();
    _setOnline(true);
    final payload = d.packet.payload;
    switch (d.packet.type) {
      case ChwpType.connectReply:
        _connectReplies.add(ConnectReply.parse(payload));
      case ChwpType.statusReply:
        final status = ConsoleStatus.parse(payload);
        lastStatus = status;
        _status.add(status);
      case ChwpType.executePageReply:
        final page = _assembler.add(ExecutePageChunk.parse(payload));
        if (page != null) {
          _executePage = page;
          _pages.add(page);
        }
      case ChwpType.windowReply:
        final info = WindowInfo.parse(payload);
        _windowHeaders.add(info);
        _playbackWindow.header(info);
      case ChwpType.windowColumnsReply:
        _windowColumns.add(WindowColumns.parse(payload));
      case ChwpType.windowItemsReply:
        final chunk = WindowItemsChunk.parse(payload);
        _windowItems.add(chunk);
        _playbackWindow.add(chunk).forEach(_playbackInfo.add);
    }
  }

  void _onCrep(List<CrepMessage> messages) {
    final update = interpretCrep(messages);
    update.playbacks.forEach(_playbacks.add);
    if (update.page != null) _playbackPages.add(update.page!);
  }

  /// Requests [page] (1-based), or the currently selected page.
  void requestExecutePage([int? page]) =>
      _transport.send(console, ChwpType.executePage, ChwpRequests.executePage(page: page));

  /// Presses or releases an item on the current Execute page.
  ///
  /// MagicQ reads the down bit the other way round for flash items: bit
  /// clear turns the flash on, bit set releases it (confirmed live; with the
  /// plain encoding a flash latched on release). A release is encoded like
  /// its press, even if the page changed in between.
  void setExecuteButton(int index, {required bool pressed}) {
    final bool flash;
    if (pressed) {
      final items = _executePage?.items;
      flash = items != null && index < items.length && items[index].isFlash;
      if (flash) _flashesDown.add(index);
    } else {
      flash = _flashesDown.remove(index);
    }
    _transport.send(
      console,
      ChwpType.executeButton,
      ChwpRequests.executeButton(index, pressed: flash ? !pressed : pressed),
    );
  }

  final Set<int> _flashesDown = {};

  /// [level] is 0..255.
  void setExecuteFader(int index, int level) {
    _pendingExecuteFaders[index] = level;
    _scheduleFlush();
  }

  /// [percent] is 0..100. Sent over CREP.
  ///
  /// MagicQ applies remote levels once per main-loop tick (~30 Hz), so
  /// while a fader moves the latest level is sent on a steady tick-rate
  /// clock rather than per touch event. Wi-Fi jitter then can't leave a
  /// tick without a fresh value, and the steady stream keeps the phone's
  /// radio awake.
  void setPlaybackLevel(int playback, double percent) {
    _playbackLevels[playback] = percent;
    _playbackMoved[playback] = DateTime.now();
    if (_levelTimer == null) {
      _sendPlaybackLevels();
      _levelTimer = Timer.periodic(levelInterval, (_) => _sendPlaybackLevels());
    }
  }

  /// Send period for moving playback faders; matches MagicQ's tick.
  static const levelInterval = Duration(milliseconds: 33);

  /// How long to keep streaming after the last movement.
  static const levelHold = Duration(milliseconds: 300);

  final Map<int, double> _playbackLevels = {};
  final Map<int, DateTime> _playbackMoved = {};
  Timer? _levelTimer;

  void _sendPlaybackLevels() {
    final now = DateTime.now();
    _playbackMoved.removeWhere((_, t) => now.difference(t) > levelHold);
    if (_playbackMoved.isEmpty) {
      _levelTimer?.cancel();
      _levelTimer = null;
      return;
    }
    sendCrep(_playbackMoved.keys.map((pb) => CrepCommand.level(pb, _playbackLevels[pb]!)).join());
  }

  /// Sends raw CREP commands, e.g. [CrepCommand.go].
  void sendCrep(String commands) {
    _crep.send(encodeCrep(commands, sequence: _crepSequence++), console, crepPort);
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: 20), _flush);
  }

  void _flush() {
    _flushTimer = null;
    _pendingExecuteFaders.forEach(
      (index, level) => _transport.send(console, ChwpType.executeFader, ChwpRequests.executeFader(index, level)),
    );
    _pendingExecuteFaders.clear();
  }

  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _pollTimer?.cancel();
    _flushTimer?.cancel();
    _levelTimer?.cancel();
    _sub.cancel();
    _transport.release();
    _crep.close();
    _connectReplies.close();
    _pages.close();
    _status.close();
    _online.close();
    _playbacks.close();
    _playbackPages.close();
    _playbackInfo.close();
    _windowHeaders.close();
    _windowItems.close();
    _windowColumns.close();
  }
}
