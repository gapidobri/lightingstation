import 'dart:convert';
import 'dart:typed_data';

import 'chmq.dart';

/// Splits a CHMQ TCP stream into frames.
class ChmqFrameReader {
  final BytesBuilder _pending = BytesBuilder(copy: false);
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;

  /// Adds received bytes and returns the complete frames they finish.
  List<Uint8List> add(List<int> data) {
    if (_offset < _buffer.length) _pending.add(Uint8List.sublistView(_buffer, _offset));
    _pending.add(data);
    _buffer = _pending.takeBytes();
    _offset = 0;
    final frames = <Uint8List>[];
    while (_buffer.length - _offset >= chmqHeaderSize) {
      final view = Uint8List.sublistView(_buffer, _offset);
      final header = parseChmqFrame(view);
      if (header == null) {
        // Out of step: skip to the next magic.
        final next = _indexOfMagic(_offset + 1);
        _offset = next < 0 ? _buffer.length - 3 : next;
        continue;
      }
      if (view.length < header.length) break;
      frames.add(Uint8List.fromList(Uint8List.sublistView(view, 0, header.length)));
      _offset += header.length;
    }
    return frames;
  }

  int _indexOfMagic(int from) {
    for (var i = from; i + 4 <= _buffer.length; i++) {
      if (_buffer[i] == 0x43 && _buffer[i + 1] == 0x48 && _buffer[i + 2] == 0x4d && _buffer[i + 3] == 0x51) return i;
    }
    return -1;
  }
}

/// One playback strip of MagicQ's on-screen faders, from a
/// [ChmqType.widget] message.
///
/// MagicQ fills the strip with `FUN_100524340` (the same text as the
/// Playbacks window's status view), shows it in widget 300 + playback - 1
/// (`FUN_100526b90`), and sends it to linked controllers from there
/// (`FUN_10047ffe0`):
///
/// ```
/// 0x0a u16 widget   0x0c u16 kind (2 = playback strip)   0x0e u16 level?
/// 0x14 u32 ?        0x18 u32 flags (low byte: 1 active, 2 idle)
/// 0x1c cstrings: label, name, current, progress, next
/// ```
///
/// Only the strips the console has on screen are sent (10 on MagicQ PC),
/// for its current playback page.
class ChmqPlaybackStrip {
  const ChmqPlaybackStrip({
    required this.playback,
    required this.label,
    required this.name,
    required this.current,
    required this.progress,
    required this.next,
    this.flags = 0,
  });

  /// Widget ID of playback 1's strip, for peers from version 9.
  static const firstWidget = 300;

  /// 1-based.
  final int playback;

  /// `PB<n>`, plus a tag such as `SP2` (speed master), `T` (test), `LC`.
  final String label;

  /// Cue stack name, or the speed master's name when it has one.
  final String name;

  /// Current cue text (`%2.2f` when it has none). For a speed master, its
  /// BPM (`%.1f BPM`).
  final String current;

  /// `ACT`, `(n)` (cue count), a fade percentage or time, or a pickup
  /// arrow (`^`, `v`).
  final String progress;

  /// Next cue text. For a speed master, its multiplier and state
  /// (`x2 Running`, `/2 Halted`, `Running`).
  final String next;

  final int flags;

  /// 1 active, 2 idle (as the Playbacks window's cell state).
  int get state => flags & 0xff;

  /// Reads a [ChmqType.widget] frame, or returns null if it isn't a
  /// playback strip.
  static ChmqPlaybackStrip? parse(Uint8List frame) {
    final header = parseChmqFrame(frame);
    if (header == null || header.type != ChmqType.widget || frame.length < 0x1c) return null;
    final data = ByteData.sublistView(frame);
    final widget = data.getUint16(0x0a, Endian.little);
    final kind = data.getUint16(0x0c, Endian.little);
    // Soft keys start at widget 400.
    if (kind != 2 || widget < firstWidget || widget >= 400) return null;
    // Frames carry stale bytes after the strings; read exactly five.
    final strings = <String>[];
    var start = 0x1c;
    for (var i = 0; i < 5; i++) {
      var end = start;
      while (end < frame.length && frame[end] != 0) {
        end++;
      }
      strings.add(latin1.decode(Uint8List.sublistView(frame, start, end)));
      start = end + 1;
      if (start > frame.length) break;
    }
    while (strings.length < 5) {
      strings.add('');
    }
    return ChmqPlaybackStrip(
      playback: widget - firstWidget + 1,
      label: strings[0],
      name: strings[1],
      current: strings[2],
      progress: strings[3],
      next: strings[4],
      flags: data.getUint32(0x18, Endian.little),
    );
  }

  /// The running cue's text, or null for a cue without text (MagicQ shows
  /// its number instead) and for speed masters.
  String? get cueText => speedMaster != null ? null : _cueText(current);

  /// The next cue's text, with the same rules as [cueText].
  String? get nextCueText => speedMaster != null ? null : _cueText(next);

  static String? _cueText(String slot) {
    final text = slot.trim();
    // With the cue number display option: "%2.2f %.12s".
    final numbered = RegExp(r'^-?\d+\.\d\d(?: (.*))?$').firstMatch(text);
    if (numbered != null) {
      final rest = numbered.group(1)?.trim();
      return rest == null || rest.isEmpty ? null : rest;
    }
    return text.isEmpty ? null : text;
  }

  /// The speed master this playback's cue stack is, or null.
  SpeedMasterInfo? get speedMaster => SpeedMasterInfo.fromStrip(this);

  @override
  String toString() => 'PB$playback [$label | $name | $current | $progress | $next]';
}

/// A playback whose cue stack is a speed master, as its strip shows it.
class SpeedMasterInfo {
  const SpeedMasterInfo({this.number, required this.bpm, this.multiplier, this.halted = false});

  /// SP number, when the strip's label names it.
  final int? number;

  /// Base tempo (`60 / period`, speed master record `+4`), or the tempo of
  /// its audio or DJ source.
  final double bpm;

  /// `x2`, `/2` and so on, or null for none (record `+0x18`: 1 = x2,
  /// 2..0x8000 = /n, above 0x8000 = x(n - 0x8000)).
  final String? multiplier;

  final bool halted;

  /// The multiplier as a factor: `x2` = 2, `/2` = 0.5; 1 without one.
  double get rate {
    final m = multiplier;
    if (m == null) return 1;
    final n = int.tryParse(m.substring(1));
    if (n == null || n == 0) return 1;
    return m.startsWith('x') ? n.toDouble() : 1 / n;
  }

  /// The tempo effects run at: [bpm] times [rate].
  double get effectiveBpm => bpm * rate;

  static final _bpm = RegExp(r'^(\d+(?:\.\d+)?) BPM$');
  static final _state = RegExp(r'^(?:([x/]\d+) )?(Running|Halted)$');
  static final _tag = RegExp(r'\bSP(\d+)$');

  /// Reads the strip text `FUN_100524340` writes for a stack with a speed
  /// master (`+0x9e`): current = `%.1f BPM`, next = multiplier (`x2 `,
  /// `/%i `, `x%i `) and `Running`/`Halted`, label tag `SP%i`.
  static SpeedMasterInfo? fromStrip(ChmqPlaybackStrip strip) {
    final bpm = _bpm.firstMatch(strip.current.trim());
    if (bpm == null) return null;
    final state = _state.firstMatch(strip.next.trim());
    final tag = _tag.firstMatch(strip.label.trim());
    // A cue could be named "120 BPM"; need the state or the tag too. The
    // state text can be replaced (fader function or pickup), the tag
    // hidden (non-level fader), but not both.
    if (state == null && tag == null) return null;
    return SpeedMasterInfo(
      number: tag == null ? null : int.parse(tag.group(1)!),
      bpm: double.parse(bpm.group(1)!),
      multiplier: state?.group(1),
      halted: state?.group(2) == 'Halted',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SpeedMasterInfo &&
      other.number == number &&
      other.bpm == bpm &&
      other.multiplier == multiplier &&
      other.halted == halted;

  @override
  int get hashCode => Object.hash(number, bpm, multiplier, halted);

  @override
  String toString() =>
      'SP${number ?? '?'} $bpm BPM${multiplier == null ? '' : ' $multiplier'}${halted ? ' halted' : ''}';
}

/// A [ChmqType.status] message (`FUN_10047f480`):
///
/// ```
/// 0x0a u16 ?   0x0c u32 ?   0x10 u16 selected window   0x12 u16 0
/// 0x14 u16, 0x16 u16   0x24 cstrings (message and command lines)
/// ```
class ChmqStatus {
  const ChmqStatus({required this.selectedWindow});

  /// What `FUN_100446430` returns when no window is selected.
  static const noWindow = 0x6d;

  /// The console's selected window, as a window table index (the same IDs
  /// as CHWP window requests), or null when none is.
  final int? selectedWindow;

  static ChmqStatus? parse(Uint8List frame) {
    final header = parseChmqFrame(frame);
    if (header == null || header.type != ChmqType.status || frame.length < 0x12) return null;
    final window = ByteData.sublistView(frame).getUint16(0x10, Endian.little);
    return ChmqStatus(selectedWindow: window == noWindow ? null : window);
  }
}
