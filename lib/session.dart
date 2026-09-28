import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:magicq_remote/magicq_remote.dart';

import 'wifi_lock.dart';

const int playbackCount = 10;

/// What the UI talks to: a live console, or an offline demo.
abstract class ConsoleSession extends ChangeNotifier {
  String get consoleName;
  bool get online;
  List<String> get statusLines => const [];
  ExecutePage? get executePage;

  /// Playback page and levels. With CREP feedback on (MagicQ in a "tx"
  /// mode) these follow the console; otherwise they are what we last sent.
  int playbackPage = 1;
  final List<double> playbackLevels = List.filled(playbackCount, 0);
  final List<bool> flashing = List.filled(playbackCount, false);
  final List<bool> playbackActive = List.filled(playbackCount, false);
  final List<String?> playbackCue = List.filled(playbackCount, null);

  /// Cue stack names as the console's playback strips show them (a named
  /// speed master shows its own name), or from MagicQ's Playbacks window
  /// while the remote link is down; null until known or without a stack.
  final List<String?> playbackName = List.filled(playbackCount, null);

  /// Current and next cue text, when MagicQ's Playbacks window is in its
  /// status view; null otherwise, or for a cue without text.
  final List<String?> playbackCueName = List.filled(playbackCount, null);
  final List<String?> playbackNextCue = List.filled(playbackCount, null);

  /// Speed master state of playbacks whose cue stack is a speed master,
  /// from the console's playback strips; null otherwise.
  final List<SpeedMasterInfo?> playbackSpeedMaster = List.filled(playbackCount, null);

  /// Whether playback state comes back from the console.
  bool get hasPlaybackFeedback => false;

  /// Text of [playback]'s running cue (0-based), when known.
  String? cueName(int playback) => playbackCueName[playback];

  /// Text of [playback]'s next cue (0-based), when known.
  String? nextCueName(int playback) => playbackNextCue[playback];

  /// Native playback buttons over MagicQ remote control: null when not
  /// available, otherwise whether the console has connected back.
  RemoteLinkState? get buttonLink => null;

  /// [playback] is 0-based; [level] is 0..1.
  void setPlaybackLevel(int playback, double level) {
    playbackLevels[playback] = level;
    sendPlaybackLevel(playback, level);
    notifyListeners();
  }

  void setFlash(int playback, bool down) {
    flashing[playback] = down;
    sendButton(PlaybackButton.flash, playback, down);
    notifyListeners();
  }

  void setGo(int playback, bool down) => sendButton(PlaybackButton.go, playback, down);
  void setPause(int playback, bool down) => sendButton(PlaybackButton.pause, playback, down);

  /// Sends a playback button over CREP. CREP calls the playback function
  /// directly, so Go and Pause act on press and have no release.
  @protected
  void sendButton(PlaybackButton button, int playback, bool down) {
    final pb = playback + 1;
    switch (button) {
      case PlaybackButton.flash:
        sendPlaybackCommand(down ? CrepCommand.test(pb) : CrepCommand.untest(pb));
      case PlaybackButton.go when down:
        sendPlaybackCommand(CrepCommand.go(pb));
      case PlaybackButton.pause when down:
        sendPlaybackCommand(CrepCommand.stop(pb));
      default:
    }
  }

  /// Reads [playback]'s cue list (0-based) and caches it. On a live console
  /// this presses the playback's Select key, so it changes the console's
  /// selected playback. Throws a [CueListException] when it can't.
  /// [onProgress] gets the cues read so far, before the list is complete.
  Future<CueList> loadCues(int playback, {void Function(CueList partial)? onProgress}) async {
    final key = (playbackPage, playback);
    final cues = await readCues(playback, onProgress: onProgress);
    _cueCache[key] = cues;
    return cues;
  }

  /// The cue list [loadCues] last read for [playback] on the current
  /// playback page, shown while it reads again.
  CueList? cachedCues(int playback) => _cueCache[(playbackPage, playback)];

  final Map<(int, int), CueList> _cueCache = {};

  @protected
  Future<CueList> readCues(int playback, {void Function(CueList partial)? onProgress});

  /// Jumps [playback] (0-based) to [cue], with the cue's own times.
  void jumpToCue(int playback, String cue) => sendPlaybackCommand(CrepCommand.jump(playback + 1, cue));

  void selectPlaybackPage(int page) {
    if (page < 1) return;
    playbackPage = page;
    sendPlaybackCommand(CrepCommand.page(page));
    notifyListeners();
  }

  void selectExecutePage(int page);
  void pressExecute(int index, {required bool down});

  /// [level] is 0..255.
  void setExecuteFader(int index, int level);

  @protected
  void sendPlaybackLevel(int playback, double level);
  @protected
  void sendPlaybackCommand(String command);
}

enum PlaybackButton { flash, go, pause }

/// A playback's cue list, as the console's Cue Stack window showed it.
typedef CueList = ({String title, List<CueStep> steps});

class CueListException implements Exception {
  CueListException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LiveSession extends ConsoleSession {
  /// [remote], when given, carries the playback buttons as native console
  /// buttons (while its link is down they fall back to CREP) and mirrors
  /// the console's playback strips (cue text, speed masters).
  LiveSession(this.client, {this.remote}) {
    WifiLock.acquire();
    final remote = this.remote;
    _subs = [
      if (remote != null)
        remote.states.listen((state) {
          if (state == RemoteLinkState.waiting) _clearStrips();
          notifyListeners();
        }),
      if (remote != null) remote.playbackStrips.listen(_onStrip),
      client.executePages.listen((_) => notifyListeners()),
      client.status.listen((s) {
        _status = s.lines.where((l) => l.trim().isNotEmpty).toList();
        notifyListeners();
      }),
      client.online.listen((online) {
        // Levels may have moved while the link was down.
        if (online) _resyncPlaybacks();
        notifyListeners();
      }),
      client.playbackStates.listen(_onPlayback),
      client.playbackInfo.listen(_onPlaybackInfo),
      client.playbackPages.listen((page) {
        playbackPage = page;
        notifyListeners();
      }),
    ];
    _resyncPlaybacks();
  }

  /// Asks the console for every playback's level and active state, so the
  /// faders start where the console's are. CREP feedback only reports
  /// changes. UDP can drop the reply, so ask twice.
  void _resyncPlaybacks() {
    client.requestPlaybackStates(1, playbackCount);
    _resyncTimer?.cancel();
    _resyncTimer = Timer(const Duration(seconds: 1), () => client.requestPlaybackStates(1, playbackCount));
  }

  Timer? _resyncTimer;

  bool _feedbackSeen = false;

  @override
  bool get hasPlaybackFeedback => _feedbackSeen;

  void _onPlayback(PlaybackState s) {
    final i = s.playback - 1;
    if (i < 0 || i >= playbackCount) return;
    _feedbackSeen = true;
    // MagicQ echoes our own level changes, slightly behind. Ignore level
    // feedback while this playback is being moved from the app.
    final recentlyMoved = DateTime.now().difference(_lastLocalLevel[i]) < const Duration(milliseconds: 400);
    if (s.level != null && !recentlyMoved) playbackLevels[i] = (s.level! / 100).clamp(0, 1);
    if (s.active != null) playbackActive[i] = s.active!;
    if (s.cue != null) playbackCue[i] = s.cue;
    notifyListeners();
  }

  void _onPlaybackInfo(PlaybackInfo info) {
    final i = info.playback - 1;
    if (i < 0 || i >= playbackCount) return;
    // The window reports a cue only while the playback is active; keep the
    // last one otherwise, as CREP feedback does.
    final cue = info.cue ?? playbackCue[i];
    // Names come from the strips while they arrive, as the console shows
    // them; the window's are kept for when the link is down.
    _windowName[i] = info.name;
    final name = _stripsSeen ? playbackName[i] : info.name;
    if (playbackName[i] == name &&
        playbackCue[i] == cue &&
        playbackCueName[i] == info.cueName &&
        playbackNextCue[i] == info.nextCue) {
      return;
    }
    playbackName[i] = name;
    playbackCue[i] = cue;
    // Cue text only comes with the status view, so this also clears it
    // when the window goes back to its standard view.
    playbackCueName[i] = info.cueName;
    playbackNextCue[i] = info.nextCue;
    notifyListeners();
  }

  // Names, cue text and speed masters from the console's playback strips,
  // which screen sync mirrors every ~250 ms for the console's current page.
  final List<String?> _stripCue = List.filled(playbackCount, null);
  final List<String?> _stripNext = List.filled(playbackCount, null);
  final List<String?> _windowName = List.filled(playbackCount, null);
  bool _stripsSeen = false;

  void _onStrip(ChmqPlaybackStrip strip) {
    final i = strip.playback - 1;
    if (i < 0 || i >= playbackCount) return;
    _stripsSeen = true;
    // The stack name (or a named speed master's name); empty without a
    // cue stack.
    final name = strip.name.trim().isEmpty ? null : strip.name.trim();
    final speedMaster = strip.speedMaster;
    final cue = strip.cueText;
    final next = strip.nextCueText;
    if (playbackName[i] == name &&
        playbackSpeedMaster[i] == speedMaster &&
        _stripCue[i] == cue &&
        _stripNext[i] == next) {
      return;
    }
    playbackName[i] = name;
    playbackSpeedMaster[i] = speedMaster;
    _stripCue[i] = cue;
    _stripNext[i] = next;
    notifyListeners();
  }

  void _clearStrips() {
    _stripsSeen = false;
    playbackName.setAll(0, _windowName);
    playbackSpeedMaster.fillRange(0, playbackCount, null);
    _stripCue.fillRange(0, playbackCount, null);
    _stripNext.fillRange(0, playbackCount, null);
  }

  final MagicQClient client;
  final MagicQRemoteControl? remote;

  // The Playbacks window's status view has cue text only on consoles with
  // wings; otherwise it comes from the strips.
  @override
  String? cueName(int playback) => playbackCueName[playback] ?? _stripCue[playback];

  @override
  String? nextCueName(int playback) => playbackNextCue[playback] ?? _stripNext[playback];

  late final List<StreamSubscription<Object?>> _subs;

  @override
  RemoteLinkState? get buttonLink => remote?.state;

  // Buttons pressed over the remote link, so the release takes the same path.
  final Set<(PlaybackButton, int)> _nativeHeld = {};

  @override
  void sendButton(PlaybackButton button, int playback, bool down) {
    final key = (button, playback);
    final remote = this.remote;
    final native = down ? remote != null && remote.isLinked : _nativeHeld.remove(key);
    if (!native) return super.sendButton(button, playback, down);
    final pb = playback + 1;
    final sent = switch (button) {
      PlaybackButton.flash => remote!.flash(pb, down: down),
      PlaybackButton.go => remote!.go(pb, down: down),
      PlaybackButton.pause => remote!.pause(pb, down: down),
    };
    if (down && sent) {
      _nativeHeld.add(key);
    } else if (down) {
      super.sendButton(button, playback, down);
    }
  }

  /// Longest wait for the Cue Stack window to switch after the Select
  /// press; it takes ~0.8-0.9 s (measured live).
  static const _selectTimeout = Duration(seconds: 3);

  /// Whether the Cue Stack window's [title] is [playback]'s stack: its
  /// strip's stack name, as in "CUE STACK (CS27: Dim FX)" (named stacks
  /// confirmed live; unnamed ones assumed to show just "CS27"), or the
  /// title of its last read list. Stacks with the same name match too.
  bool _showsStack(String title, int playback) {
    final cached = cachedCues(playback)?.title;
    if (cached != null && cached.isNotEmpty && cached == title) return true;
    final name = playbackName[playback];
    final inner = RegExp(r'\((.*)\)\s*$').firstMatch(title)?.group(1)?.trim();
    if (name == null || inner == null) return false;
    return inner == name || inner.endsWith(': $name');
  }

  @override
  Future<CueList> readCues(int playback, {void Function(CueList partial)? onProgress}) async {
    // CREP has no select, and the Cue Stack window follows the console's
    // selected playback, so this needs the remote control link.
    final remote = this.remote;
    if (remote == null || !remote.isLinked) {
      throw CueListException('The cue list needs the remote control link (RC), which is not connected.');
    }
    final button = ChmqButtons.select(playback + 1);
    try {
      // MagicQ switches the Cue Stack window well after the press, so read
      // the old title first and wait for it to change; reading at once
      // shows the previously selected stack.
      final before = await client.waitForCueStackTitle((_) => true, timeout: const Duration(seconds: 1));
      if (!remote.setButton(button, pressed: true)) throw CueListException('The remote control link dropped.');
      remote.setButton(button, pressed: false);
      if (!_showsStack(before, playback)) {
        try {
          await client.waitForCueStackTitle((t) => t != before, timeout: _selectTimeout);
        } on TimeoutException {
          throw CueListException('The console did not switch its Cue Stack window to PB ${playback + 1}.');
        }
      }
      return await client.readCueStack(onProgress: onProgress);
    } on TimeoutException {
      throw CueListException('No reply from the console for the Cue Stack window.');
    } on MagicQConnectException catch (e) {
      throw CueListException(e.message);
    }
  }

  List<String> _status = const [];

  @override
  String get consoleName => client.consoleName.isNotEmpty ? client.consoleName : client.console.address;

  @override
  bool get online => client.isOnline;

  @override
  List<String> get statusLines => _status;

  @override
  ExecutePage? get executePage => client.executePage;

  @override
  void selectExecutePage(int page) {
    if (page >= 1) client.requestExecutePage(page);
  }

  @override
  void pressExecute(int index, {required bool down}) => client.setExecuteButton(index, pressed: down);

  @override
  void setExecuteFader(int index, int level) => client.setExecuteFader(index, level);

  @override
  void sendPlaybackLevel(int playback, double level) {
    _lastLocalLevel[playback] = DateTime.now();
    client.setPlaybackLevel(playback + 1, level * 100);
  }

  final List<DateTime> _lastLocalLevel = List.filled(playbackCount, DateTime(0));

  @override
  void sendPlaybackCommand(String command) => client.sendCrep(command);

  @override
  void dispose() {
    _resyncTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    remote?.close();
    client.close();
    WifiLock.release();
    super.dispose();
  }
}

/// Runs the UI without a console, with a made-up Execute page.
class DemoSession extends ConsoleSession {
  DemoSession() {
    _buildPage(1);
    const names = ['Front wash', 'Back light', 'Movers', 'Specials', 'Haze', 'Strobe FX', 'Colour chase', 'Audience'];
    playbackName.setAll(0, names);
    playbackCueName.setAll(0, const ['House to half', 'Walk in', 'Opening look']);
    playbackNextCue.setAll(0, const ['Blackout', 'Preset', 'Song 1 verse']);
    playbackSpeedMaster[5] = const SpeedMasterInfo(number: 1, bpm: 128, multiplier: 'x2');
    // Button labels from the console (see PlaybackStrip).
    playbackCueName[4] = 'E5 Haze on';
    playbackNextCue[4] = 'E15 Haze off';
  }

  static const _columns = 8;
  static const _rows = 4;
  static const _names = [
    'Warm wash',
    'Cool wash',
    'Front',
    'Back',
    'Audience',
    'Haze',
    'Strobe',
    'Blinder',
    'Red',
    'Orange',
    'Amber',
    'Green',
    'Cyan',
    'Blue',
    'Magenta',
    'White',
    'Ballyhoo',
    'Circle',
    'Fan out',
    'Chase',
    'Rainbow',
    'Pulse',
    'Sparkle',
    'Blackout',
  ];
  static const _colours = [
    0xE8A33D,
    0x4F9DFF,
    0xD9D2C0,
    0x9B7BFF,
    0xF2F2F2,
    0x7F8C99,
    0xFFFFFF,
    0xFFD27A,
    0xFF3B30,
    0xFF8A1F,
    0xFFB020,
    0x34C759,
    0x32D2E0,
    0x2F6BFF,
    0xE040C8,
    0xF4F4F4,
    0xC08BFF,
    0x7DD3FC,
    0x86EFAC,
    0xFDA4AF,
    0xFACC15,
    0xF472B6,
    0xA5B4FC,
    0x444A52,
  ];

  late ExecutePage _page;
  final Set<int> _active = {};

  @override
  String get consoleName => 'Demo';

  // Pretend to be a console in "tx" mode, so feedback UI is visible.
  @override
  bool get hasPlaybackFeedback => true;

  @override
  void setGo(int playback, bool down) {
    if (!down) return;
    playbackActive[playback] = true;
    playbackCue[playback] = '${(int.tryParse(playbackCue[playback] ?? '0') ?? 0) + 1}';
    notifyListeners();
  }

  @override
  Future<CueList> readCues(int playback, {void Function(CueList partial)? onProgress}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    const texts = ['House to half', 'Walk in', 'Opening look', 'Song 1 verse', 'Song 1 chorus', '', 'Blackout'];
    final name = playbackName[playback] ?? 'CS${playback + 1}';
    return (
      title: 'Cue Stack - $name',
      steps: [
        for (var i = 0; i < 12; i++)
          CueStep(step: i, cue: i == 3 ? '3.5' : '${i < 3 ? i + 1 : i}', text: texts[(i + playback) % texts.length]),
      ],
    );
  }

  @override
  void jumpToCue(int playback, String cue) {
    playbackActive[playback] = true;
    playbackCue[playback] = cue;
    notifyListeners();
  }

  @override
  void setPause(int playback, bool down) {
    if (!down) return;
    playbackActive[playback] = false;
    notifyListeners();
  }

  @override
  void setPlaybackLevel(int playback, double level) {
    if (level > 0 && !playbackActive[playback]) {
      playbackActive[playback] = true;
      playbackCue[playback] ??= '1';
    }
    super.setPlaybackLevel(playback, level);
  }

  @override
  bool get online => true;

  @override
  List<String> get statusLines => const ['Demo mode, not connected to a console'];

  @override
  ExecutePage? get executePage => _page;

  /// Demo regions: a 4x2 block top left, the cue stack row, and the faders.
  static int _region(int row, int col) {
    if (row < 0 || col < 0 || col >= _columns) return 0;
    if (row < 2 && col < 4) return 1;
    if (row == 2) return 2;
    if (row == 3 && col < 4) return 3;
    return 0;
  }

  /// Region edge bits as MagicQ sends them (top, bottom, left, right).
  static int _regionEdges(int row, int col) {
    final region = _region(row, col);
    if (region == 0) return 0;
    return (_region(row - 1, col) != region ? 1 : 0) |
        (_region(row + 1, col) != region ? 2 : 0) |
        (_region(row, col - 1) != region ? 4 : 0) |
        (_region(row, col + 1) != region ? 8 : 0);
  }

  void _buildPage(int page) {
    final items = <ExecuteItem>[];
    for (var i = 0; i < _columns * _rows; i++) {
      final row = i ~/ _columns;
      final col = i % _columns;
      final on = _active.contains(i);
      if (row == 3) {
        // Bottom row: four faders, a flash item (on only while held), a
        // two-cell-wide item, and the cell it covers.
        items.add(switch (col) {
          < 4 => ExecuteItem(
            index: i,
            flags: 0x8011,
            borders: _regionEdges(row, col),
            extra: 0x80,
            state: 0x80000000 | const [0xFFB020, 0x4F9DFF, 0xE040C8, 0xF4F4F4][col],
            level: const [255, 128, 64, 0][col],
            name: const ['Master', 'FX speed', 'FX size', 'Haze'][col],
            tag: 'LVL',
          ),
          4 => ExecuteItem(
            index: i,
            flags: 0x8009,
            extra: on ? 0x80 : 0,
            state: 0x80000000 | 0xFFFFFF,
            name: 'Strobe hit',
            tag: 'FL',
          ),
          5 => ExecuteItem(
            index: i,
            flags: 0x8001,
            extra: 0x10000000 | (on ? 0x80 : 0),
            state: 0x80000000 | 0x444A52,
            name: 'All off',
            tag: 'PB',
          ),
          _ => ExecuteItem.empty(i),
        });
        continue;
      }
      final nameIndex = (i + (page - 1) * 3) % _names.length;
      items.add(
        ExecuteItem(
          index: i,
          flags: 0x8001,
          borders: _regionEdges(row, col),
          extra: on ? 0x80 : 0,
          state: 0x80000000 | _colours[nameIndex],
          name: _names[nameIndex],
          tag: row == 2 ? 'CS' : 'PB',
        ),
      );
    }
    _page = ExecutePage(
      page: page,
      name: page == 1 ? 'Main' : 'Page $page',
      columns: _columns,
      rows: _rows,
      flags: 0,
      items: items,
    );
  }

  @override
  void selectExecutePage(int page) {
    if (page < 1) return;
    _active.clear();
    _buildPage(page);
    notifyListeners();
  }

  void _replaceItems(ExecuteItem Function(ExecuteItem item) update) {
    _page = ExecutePage(
      page: _page.page,
      name: _page.name,
      columns: _page.columns,
      rows: _page.rows,
      flags: 0,
      items: [for (final item in _page.items) update(item)],
    );
    notifyListeners();
  }

  @override
  void pressExecute(int index, {required bool down}) {
    // Flash items are on while held; the rest toggle on press.
    if (_page.items[index].isFlash) {
      down ? _active.add(index) : _active.remove(index);
    } else {
      if (!down) return;
      if (!_active.remove(index)) _active.add(index);
    }
    final levels = {for (final i in _page.items) i.index: i.level};
    _buildPage(_page.page);
    _replaceItems((item) => item.isFader ? item.copyWith(level: levels[item.index]) : item);
  }

  @override
  void setExecuteFader(int index, int level) =>
      _replaceItems((item) => item.index == index ? item.copyWith(level: level) : item);

  @override
  void sendPlaybackLevel(int playback, double level) {}

  @override
  void sendPlaybackCommand(String command) {}
}
