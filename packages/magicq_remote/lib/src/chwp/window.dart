import 'dart:typed_data';

import 'packet.dart';

/// MagicQ window ids (index into the console's window table; the names are
/// at `0x101e3dfa0`, 20 bytes each).
abstract final class MagicQWindow {
  static const stackStore = 0x0d;
  static const cueStack = 0x0e;
  static const cueStore = 0x10;

  /// The Playbacks window (`PlaybackBoxs`).
  static const playbacks = 0x11;
  static const execute = 0x1b;
}

/// Reply to a window request (0x8006): the window's header.
///
/// ```
/// 0x00 u16 window   0x02 u16 kind (1 = table, column headers follow)
/// 0x04 u16 view     0x06 u16 ?
/// 0x08 u32 items    0x0c u32 columns   0x10 u32 ?
/// 0x14 u16 title length, then the title
/// ```
class WindowInfo {
  WindowInfo({required this.window, required this.view, required this.items, required this.columns, this.title = ''});

  final int window;

  /// The window's current view (its soft-key view selection).
  final int view;
  final int items;
  final int columns;
  final String title;

  static WindowInfo parse(Uint8List payload) {
    final r = PayloadReader(payload);
    final window = r.u16();
    r.u16();
    final view = r.u16();
    r.u16();
    final items = r.u32();
    final columns = r.u32();
    r.u32();
    final title = r.remaining >= 2 ? r.string(r.u16()) : '';
    return WindowInfo(window: window, view: view, items: items, columns: columns, title: title);
  }
}

/// Column headers of a table window (0x8008), from window table `+0x3266`
/// (40 bytes each): `u16 window`, `u16 count`, then the names as cstrings.
class WindowColumns {
  WindowColumns({required this.window, required this.names});

  final int window;
  final List<String> names;

  static WindowColumns parse(Uint8List payload) {
    final r = PayloadReader(payload);
    final window = r.u16();
    final count = r.u16();
    final names = <String>[for (var i = 0; i < count && r.remaining > 0; i++) r.cString()];
    return WindowColumns(window: window, names: names);
  }
}

/// One cell of a MagicQ window, as sent in 0x8007 (`FUN_100543d60`).
///
/// ```
/// u16 index    u16 length of this item (header and strings)
/// u16 value    u16 flags (bit 0 set, bit 2 cursor, bit 5 empty)
/// u32 colour   u32 state
/// cstring text, cstring name, cstring value
/// ```
class WindowItem {
  const WindowItem({
    required this.index,
    this.value = 0,
    this.flags = 0,
    this.colour = 0,
    this.state = 0,
    this.text = '',
    this.name = '',
    this.detail = '',
  });

  final int index;
  final int value;
  final int flags;
  final int colour;
  final int state;
  final String text;
  final String name;
  final String detail;
}

/// One 0x8007 datagram. MagicQ splits a window's items over several, each
/// carrying its own item indices, so they can be used as they arrive.
class WindowItemsChunk {
  WindowItemsChunk({required this.window, required this.page, required this.items});

  final int window;

  /// The window's page, for clients from v2.17 up.
  final int page;
  final List<WindowItem> items;

  static WindowItemsChunk parse(Uint8List payload) {
    final r = PayloadReader(payload);
    final id = r.u16();
    final count = r.u16();
    final items = <WindowItem>[];
    for (var i = 0; i < count && r.remaining >= 16; i++) {
      final start = r.offset;
      final index = r.u16();
      final length = r.u16();
      final value = r.u16();
      final flags = r.u16();
      final colour = r.u32();
      final state = r.u32();
      items.add(
        WindowItem(
          index: index,
          value: value,
          flags: flags,
          colour: colour,
          state: state,
          text: r.cString(),
          name: r.cString(),
          detail: r.cString(),
        ),
      );
      if (length >= 16) r.offset = (start + length).clamp(0, payload.length);
    }
    return WindowItemsChunk(window: id & 0xff, page: id >> 8, items: items);
  }
}

/// One step of a cue stack, as the Cue Stack window lists it.
class CueStep {
  const CueStep({required this.step, required this.cue, this.text = ''});

  /// 0-based row in the stack.
  final int step;

  /// Cue ID as CREP writes it: "5", "5.5".
  final String cue;

  /// The step's text; empty when it has none.
  final String text;

  @override
  String toString() => text.isEmpty ? 'Q$cue' : 'Q$cue $text';
}

/// Reads the steps of the stack the Cue Stack window shows: the console's
/// selected playback, unless the window is locked to a stack
/// (`FUN_100355230`). In its default view the column headers (0x8008,
/// table at `0x101c264ac`) include "Cue id" (`%2.2f`) and "Cue text"
/// (step `+4`); item index = step * columns + column, and the row after
/// the last step reads "End".
class CueStackReader {
  WindowInfo? _info;
  List<String> _columns = const [];
  final Map<int, WindowItem> _items = {};

  /// The window's title, once a header has arrived.
  String get title => _info?.title ?? '';

  void header(WindowInfo info) {
    if (info.window != MagicQWindow.cueStack) return;
    _info = info;
    _items.clear();
  }

  void columns(WindowColumns columns) {
    if (columns.window == MagicQWindow.cueStack) _columns = columns.names;
  }

  void add(WindowItemsChunk chunk) {
    if (chunk.window != MagicQWindow.cueStack) return;
    for (final item in chunk.items) {
      _items[item.index] = item;
    }
  }

  /// The steps read so far, or null when the window isn't in a view with a
  /// cue ID column.
  List<CueStep>? get steps {
    final width = _info?.columns ?? _columns.length;
    int column(String name) => _columns.indexWhere((c) => c.trim().toLowerCase() == name);
    final idColumn = column('cue id');
    final textColumn = column('cue text');
    if (width == 0 || idColumn < 0) return null;
    final steps = <CueStep>[];
    for (var step = 0; ; step++) {
      final id = _items[step * width + idColumn];
      final match = id == null ? null : RegExp(r'^\s*(\d+(?:\.\d+)?)\s*$').firstMatch(id.text);
      if (match == null) break;
      final text = textColumn < 0 ? '' : _items[step * width + textColumn]?.text.trim() ?? '';
      steps.add(CueStep(step: step, cue: _trimCue(match.group(1)!), text: text));
    }
    return steps;
  }

  static String _trimCue(String s) => s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

/// Views of the Playbacks window (window table `+0x892c`).
abstract final class PlaybackWindowView {
  /// One cell per playback: number, stack name, cue number.
  static const standard = 0;

  /// A column per playback, desk style: a label cell (`PB<n>`, stack name,
  /// progress), and below it the current and next cue text.
  static const status = 4;
}

/// Name and cue of a playback, read from the Playbacks window.
class PlaybackInfo {
  const PlaybackInfo({required this.playback, required this.name, this.cue, this.cueName, this.nextCue, this.cueCount});

  /// 1-based.
  final int playback;

  /// Cue stack name, or MagicQ's default `CS<n>` when it has none.
  final String name;

  /// Current cue ID (e.g. "5.5"), when reported.
  final String? cue;

  /// Current cue's text, from the status view only; null when the cue has
  /// no text (MagicQ then shows its number, reported as [cue]).
  final String? cueName;

  /// Next cue's text or number, from the status view only.
  final String? nextCue;

  /// Number of cues in the stack, from the standard view while the
  /// playback is idle.
  final int? cueCount;

  /// Reads a Playbacks window item, in its default view, as built by
  /// `FUN_10041d750`: text `PB<n>` (plus " T" or " DEF"), name = cue stack
  /// name (`%.15s`, or `CS<n>`), detail = current cue as `%2.2f` while
  /// active, otherwise the stack's cue count as `%i`. Wing items (`W1-2`),
  /// headers and other views return null.
  static PlaybackInfo? fromItem(WindowItem item) {
    final playback = _labelPlayback(item);
    if (playback == null) return null;
    final detail = item.detail.trim();
    final active = detail.contains('.');
    return PlaybackInfo(
      playback: playback,
      name: item.name,
      cue: active ? _trimCue(detail) : null,
      cueCount: active ? null : int.tryParse(detail),
    );
  }

  /// Reads a status-view column: [label] from `FUN_100524340`'s label,
  /// stack name and progress, and [cueCell] (the cell below it) with the
  /// current cue text (step `+4`, or `%2.2f` when it has none, or
  /// `%2.2f %.12s` with the cue-number display option) and the next cue.
  static PlaybackInfo? fromStatusColumn(WindowItem label, WindowItem? cueCell) {
    final playback = _labelPlayback(label);
    if (playback == null) return null;
    // Upper-bank columns have a fader (flags bit 15) or Flash key (bit 7,
    // "FL") below the label instead of cue text.
    if (cueCell == null || cueCell.flags & 0x8080 != 0 || cueCell.name == 'FL') {
      return PlaybackInfo(playback: playback, name: label.name);
    }
    final current = cueCell.text.trim();
    final next = cueCell.name.trim();
    String? cue;
    String? cueName;
    final numbered = RegExp(r'^(\d+\.\d+)(?: (.*))?$').firstMatch(current);
    if (numbered != null) {
      cue = _trimCue(numbered.group(1)!);
      final text = numbered.group(2)?.trim();
      cueName = text == null || text.isEmpty ? null : text;
    } else if (current.isNotEmpty) {
      cueName = current;
    }
    return PlaybackInfo(
      playback: playback,
      name: label.name,
      cue: cue,
      cueName: cueName,
      nextCue: next.isEmpty ? null : next,
    );
  }

  static int? _labelPlayback(WindowItem item) {
    final match = RegExp(r'^PB(\d+)\b').firstMatch(item.text);
    if (match == null || item.name.isEmpty) return null;
    return int.parse(match.group(1)!);
  }

  /// "5.50" → "5.5", "1.00" → "1", matching CREP's cue format.
  static String _trimCue(String s) => s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

/// Turns Playbacks window replies into [PlaybackInfo], in either view.
///
/// The status view needs two cells per playback (label and the cell a row
/// below), which may arrive in different datagrams, so items are kept
/// until the next header.
class PlaybackWindowReader {
  WindowInfo? _info;
  final Map<int, WindowItem> _items = {};

  /// The window's current view, once a header has arrived.
  int? get view => _info?.view;

  void header(WindowInfo info) {
    if (info.window != MagicQWindow.playbacks) return;
    _info = info;
    _items.clear();
  }

  List<PlaybackInfo> add(WindowItemsChunk chunk) {
    if (chunk.window != MagicQWindow.playbacks) return const [];
    final info = _info;
    if (info == null || info.view != PlaybackWindowView.status || info.columns == 0) {
      return chunk.items.map(PlaybackInfo.fromItem).whereType<PlaybackInfo>().toList();
    }
    for (final item in chunk.items) {
      _items[item.index] = item;
    }
    return [
      for (final label in _items.values) ?PlaybackInfo.fromStatusColumn(label, _items[label.index + info.columns]),
    ];
  }
}
