import 'dart:typed_data';

import 'package:magicq_remote/magicq_remote.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) => Uint8List.fromList([for (final b in s.split(' ')) int.parse(b, radix: 16)]);

/// A playback strip frame: [widget], flags, then the five strings.
Uint8List _strip(int widget, List<String> strings, {int flags = 0x100002}) {
  final head = ByteData(0x12)
    ..setUint16(0, widget, Endian.little)
    ..setUint16(2, 2, Endian.little)
    ..setUint16(4, 0x6a, Endian.little)
    ..setUint32(0x0e, flags, Endian.little);
  return encodeChmq(ChmqType.widget, [
    ...head.buffer.asUint8List(),
    for (final s in strings) ...[...s.codeUnits, 0],
  ]);
}

void main() {
  group('playback strip', () {
    test('parses a strip captured from MagicQ 1.9.7.3 (PB10, speed master SP2)', () {
      // Frame body as sent to MagicQ's own controller, with its trailing
      // stale bytes.
      final frame = encodeChmq(
        ChmqType.widget,
        _hex(
          '35 01 02 00 6a 00 00 00 00 00 00 00 00 00 01 00 11 00 50 42 31 30 20 53 50 32 00 49 6e 74 20 53 50 '
          '4d 00 31 32 37 2e 39 20 42 50 4d 00 5e 00 52 75 6e 6e 69 6e 67 00 20 52 4e',
        ),
      );
      final strip = ChmqPlaybackStrip.parse(frame)!;
      expect(strip.playback, 10);
      expect(strip.label, 'PB10 SP2');
      expect(strip.name, 'Int SPM');
      expect(strip.current, '127.9 BPM');
      expect(strip.progress, '^');
      expect(strip.next, 'Running');
      expect(strip.state, 1);
      expect(strip.cueText, isNull);
      expect(strip.speedMaster, const SpeedMasterInfo(number: 2, bpm: 127.9));
    });

    test('reads cue text for a normal stack', () {
      final strip = ChmqPlaybackStrip.parse(_strip(300, ['PB1', 'Beami', 'E1 Blinder', '(1) ', 'E11 Strobe']))!;
      expect(strip.playback, 1);
      expect(strip.speedMaster, isNull);
      expect(strip.cueText, 'E1 Blinder');
      expect(strip.nextCueText, 'E11 Strobe');
    });

    test('a cue without text shows its number, which is not a name', () {
      expect(ChmqPlaybackStrip.parse(_strip(301, ['PB2', 'CS4', ' 2.50', 'ACT ', '']))!.cueText, isNull);
      expect(ChmqPlaybackStrip.parse(_strip(301, ['PB2', 'CS4', '2.50 Chorus', 'ACT ', '']))!.cueText, 'Chorus');
    });

    test('ignores soft keys and other widgets', () {
      expect(ChmqPlaybackStrip.parse(_strip(400, ['Next Page', '', '', '', ''])), isNull);
      final softKey = encodeChmq(
        ChmqType.widget,
        _hex('c8 00 00 00 00 00 00 00 00 00 00 00 00 00 03 02 00 00 56 49 45 57 00 50 4c 41 59 42 41 43 4b 53 00 00'),
      );
      expect(ChmqPlaybackStrip.parse(softKey), isNull);
    });
  });

  group('speed master', () {
    SpeedMasterInfo? sm(String label, String current, String next) =>
        ChmqPlaybackStrip.parse(_strip(300, [label, 'SP', current, 'ACT ', next]))!.speedMaster;

    test('multiplier and state', () {
      expect(sm('PB1 SP1', '120.0 BPM', 'x2 Running'), const SpeedMasterInfo(number: 1, bpm: 120, multiplier: 'x2'));
      expect(
        sm('PB1 SP3', '90.0 BPM', '/2 Halted'),
        const SpeedMasterInfo(number: 3, bpm: 90, multiplier: '/2', halted: true),
      );
      final x4 = sm('PB1 SP1', '60.0 BPM', 'x4 Running')!;
      expect(x4.rate, 4);
      expect(x4.effectiveBpm, 240);
      expect(sm('PB1 SP1', '100.0 BPM', '/4 Running')!.effectiveBpm, 25);
    });

    test('needs the state or the SP tag, so a cue named "120 BPM" is not one', () {
      expect(sm('PB1', '120 BPM', 'Next cue'), isNull);
      // A non-level fader hides the tag; the state still identifies it.
      expect(sm('PB1 SPM', '120.0 BPM', 'Running'), const SpeedMasterInfo(bpm: 120));
      // A fader function replaces the state; the tag still identifies it.
      expect(sm('PB1 SP2', '75.5 BPM', 'SP50%'), const SpeedMasterInfo(number: 2, bpm: 75.5));
    });
  });

  test('status carries the selected window', () {
    // Captured: the Playbacks window (0x11) selected.
    final frame = encodeChmq(ChmqType.status, _hex('03 00 00 00 00 00 11 00 00 00 00 00 01 00 00 00'));
    expect(ChmqStatus.parse(frame)!.selectedWindow, 0x11);
    final none = encodeChmq(ChmqType.status, _hex('03 00 00 00 00 00 6d 00 00 00'));
    expect(ChmqStatus.parse(none)!.selectedWindow, isNull);
  });

  test('link flags message matches what MagicQ\'s controller sends', () {
    expect(chmqLinkFlags(ChmqLinkFlags.screenSync), [...'CHMQ'.codeUnits, chmqVersion, 0, 14, 0, 6, 0, 5, 0, 0, 0]);
  });

  test('frame reader splits a stream at any chunk boundary', () {
    final frames = [
      chmqHello(),
      _strip(300, ['PB1', 'A', 'B', 'C', 'D']),
      chmqLinkFlags(5),
    ];
    final stream = [for (final f in frames) ...f];
    for (var cut = 1; cut < stream.length; cut++) {
      final reader = ChmqFrameReader();
      final out = [...reader.add(stream.sublist(0, cut)), ...reader.add(stream.sublist(cut))];
      expect(out, frames, reason: 'cut at $cut');
    }
  });

  test('frame reader skips bytes that are out of step', () {
    final reader = ChmqFrameReader();
    expect(reader.add([1, 2, 3, ...chmqHello()]), [chmqHello()]);
  });
}
