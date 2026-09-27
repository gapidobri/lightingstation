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

  /// Whether playback state comes back from the console.
  bool get hasPlaybackFeedback => false;

  /// [playback] is 0-based; [level] is 0..1.
  void setPlaybackLevel(int playback, double level) {
    playbackLevels[playback] = level;
    sendPlaybackLevel(playback, level);
    notifyListeners();
  }

  void setFlash(int playback, bool down) {
    flashing[playback] = down;
    sendPlaybackCommand(down ? CrepCommand.test(playback + 1) : CrepCommand.untest(playback + 1));
    notifyListeners();
  }

  void go(int playback) => sendPlaybackCommand(CrepCommand.go(playback + 1));
  void pause(int playback) => sendPlaybackCommand(CrepCommand.stop(playback + 1));

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

class LiveSession extends ConsoleSession {
  LiveSession(this.client) {
    WifiLock.acquire();
    _subs = [
      client.executePages.listen((_) => notifyListeners()),
      client.status.listen((s) {
        _status = s.lines.where((l) => l.trim().isNotEmpty).toList();
        notifyListeners();
      }),
      client.online.listen((_) => notifyListeners()),
      client.playbackStates.listen(_onPlayback),
      client.playbackPages.listen((page) {
        playbackPage = page;
        notifyListeners();
      }),
    ];
  }

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

  final MagicQClient client;
  late final List<StreamSubscription<Object?>> _subs;
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
    for (final s in _subs) {
      s.cancel();
    }
    client.close();
    WifiLock.release();
    super.dispose();
  }
}

/// Runs the UI without a console, with a made-up Execute page.
class DemoSession extends ConsoleSession {
  DemoSession() {
    _buildPage(1);
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
  void go(int playback) {
    playbackActive[playback] = true;
    playbackCue[playback] = '${(int.tryParse(playbackCue[playback] ?? '0') ?? 0) + 1}';
    notifyListeners();
  }

  @override
  void pause(int playback) {
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

  void _buildPage(int page) {
    final items = <ExecuteItem>[];
    for (var i = 0; i < _columns * _rows; i++) {
      final row = i ~/ _columns;
      final col = i % _columns;
      if (row == 3) {
        // Bottom row: two-cell-tall faders are not needed for the demo;
        // four single faders and four empties.
        items.add(
          col < 4
              ? ExecuteItem(
                  index: i,
                  flags: 0x8011,
                  extra: 0x80,
                  state: 0x80000000 | const [0xFFB020, 0x4F9DFF, 0xE040C8, 0xF4F4F4][col],
                  level: const [255, 128, 64, 0][col],
                  name: const ['Master', 'FX speed', 'FX size', 'Haze'][col],
                  tag: 'LVL',
                )
              : ExecuteItem.empty(i),
        );
        continue;
      }
      final nameIndex = (i + (page - 1) * 3) % _names.length;
      final on = _active.contains(i);
      items.add(
        ExecuteItem(
          index: i,
          flags: 0x8001,
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
    if (!down) return;
    if (!_active.remove(index)) _active.add(index);
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
