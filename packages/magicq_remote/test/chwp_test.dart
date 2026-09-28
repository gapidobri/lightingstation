import 'dart:typed_data';

import 'package:magicq_remote/magicq_remote.dart';
import 'package:test/test.dart';

/// Reference scrambler transcribed from MagicQ's sender (two bytes per
/// iteration, as in the binary) to check [scramble] matches it exactly.
Uint8List referenceScramble(List<int> plain, int seed) {
  final b = Uint8List.fromList(plain);
  var k = seed;
  var i = 0;
  int rot(int x) => ((x << 2) | (x >> 6)) & 0xff;
  for (; i + 1 < b.length; i += 2) {
    final p0 = b[i], p1 = b[i + 1];
    b[i] = p0 ^ k;
    final k1 = rot((p0 + k + i + 0x93) & 0xff);
    b[i + 1] = p1 ^ k1;
    k = rot((k1 + p1 + i + 0x94) & 0xff);
  }
  if (i < b.length) b[i] ^= k;
  return b;
}

Uint8List payloadOf(void Function(PayloadWriter w) build) {
  final w = PayloadWriter();
  build(w);
  return w.toBytes();
}

void main() {
  group('cipher', () {
    test('matches MagicQ reference for odd and even lengths', () {
      for (final len in [22, 23, 116, 1499]) {
        final plain = List<int>.generate(len, (i) => i == 0 ? 0x43 : (i * 37) & 0xff);
        for (final seed in [0, 0x5a, 0xff]) {
          expect(scramble(plain, seed), referenceScramble(plain, seed));
        }
      }
    });

    test('unscramble inverts scramble without knowing the seed', () {
      final plain = [0x43, 0x48, 0x57, 0x50, ...List.generate(40, (i) => i)];
      expect(unscramble(scramble(plain, 0x9c)), plain);
    });
  });

  group('packet', () {
    test('round trips header and payload', () {
      final packet = ChwpPacket(
        type: ChwpType.executeButton,
        sequence: 513,
        payload: ChwpRequests.executeButton(7, pressed: true),
      );
      final decoded = ChwpPacket.decode(packet.encode())!;
      expect(decoded.type, ChwpType.executeButton);
      expect(decoded.sequence, 513);
      expect(decoded.versionMajor, 2);
      expect(decoded.versionMinor, 0x19);
      expect(decoded.payload, [7, 0, 1, 0]);
    });

    test('rejects non-CHWP data', () {
      expect(ChwpPacket.decode(Uint8List(30)), isNull);
    });
  });

  group('execute page', () {
    Uint8List chunk({
      required int start,
      required List<String> names,
      int flags = 0x0011, // exists + fader
      int extra = 0x80, // active in colour mode
      int state = 0x80ff8000,
    }) {
      final header = payloadOf(
        (w) => w
          ..u32(2)
          ..u16(3) // page
          ..u16(2) // columns
          ..u16(2),
      ); // rows
      final name = Uint8List(16)..setRange(0, 4, 'Main'.codeUnits);
      final items = payloadOf((w) {
        w.u16(start);
        for (final n in names) {
          w
            ..u16(flags)
            ..u16(0)
            ..u32(extra)
            ..u32(state)
            ..u32(0)
            ..u16(200)
            ..cString('')
            ..cString(n)
            ..cString('PB');
        }
      });
      // Stale bytes MagicQ leaves after the last item.
      final padding = List.filled(64, 0xab);
      return Uint8List.fromList([...header, ...name, ...items, ...padding]);
    }

    test('parses items and ignores padding', () {
      final c = ExecutePageChunk.parse(chunk(start: 0, names: ['Wash', 'Spot', 'Beam', 'Strobe']));
      expect(c.page, 3);
      expect(c.name, 'Main');
      expect(c.columns, 2);
      expect(c.items, hasLength(4));
      final item = c.items[1];
      expect(item.name, 'Spot');
      expect(item.tag, 'PB');
      expect(item.isFader, isTrue);
      expect(item.level, 200);
      expect(item.rgb, 0xff8000);
      expect(item.active, isTrue);
    });

    test('assembles a page split across datagrams', () {
      final assembler = ExecutePageAssembler();
      expect(assembler.add(ExecutePageChunk.parse(chunk(start: 0, names: ['A', 'B']))), isNull);
      final page = assembler.add(ExecutePageChunk.parse(chunk(start: 2, names: ['C', 'D'])))!;
      expect(page.items.map((i) => i.name), ['A', 'B', 'C', 'D']);
      expect(page.itemAt(1, 0).name, 'C');
    });

    test('gives an active group item without a colour its colour back', () {
      // As captured live: flags 0x401, inactive = dimmed colour, active = state 1.
      ExecuteItem group(ExecutePageAssembler a, int state) => a
          .add(
            ExecutePageChunk.parse(
              chunk(start: 0, names: ['G1', 'G2', 'G3', 'G4'], flags: 0x401, extra: 0, state: state),
            ),
          )!
          .items
          .first;

      final seen = ExecutePageAssembler();
      final inactive = group(seen, 0x805f0018);
      expect((inactive.active, inactive.rgb), (false, 0x5f0018));
      final active = group(seen, 1);
      expect((active.active, active.rgb), (true, 0xba002f));

      final fresh = group(ExecutePageAssembler(), 1);
      expect((fresh.active, fresh.rgb), (true, 0xbb0030));
    });

    test('reads item sizes from the top byte of extra', () {
      const item = ExecuteItem(index: 0, flags: 1, extra: 0x21000080);
      expect(item.width, 3);
      expect(item.height, 2);
      expect(const ExecuteItem(index: 0).width, 1);
      expect(const ExecuteItem(index: 0, flags: 0x11, borders: 0x80).height, 2);
    });

    test('reads region edges from the low border bits', () {
      const item = ExecuteItem(index: 0, flags: 1, borders: 0x85); // top, left, tall fader
      expect((item.regionTop, item.regionBottom, item.regionLeft, item.regionRight), (true, false, true, false));
      expect(item.hasRegionEdge, isTrue);
      expect(const ExecuteItem(index: 0, flags: 1, borders: 0x280).hasRegionEdge, isFalse);
    });

    test('layout spans sized items and skips the cells they cover', () {
      ExecutePage page(List<ExecuteItem> items) =>
          ExecutePage(page: 1, name: '', columns: 3, rows: 2, flags: 0, items: items);
      final cells = page([
        const ExecuteItem(index: 0, flags: 1, extra: 0x11000000), // 2x2
        const ExecuteItem(index: 1, flags: 1, name: 'covered'),
        const ExecuteItem(index: 2, flags: 1, extra: 0x30000000), // 4 wide, clipped to 1
        const ExecuteItem.empty(3),
        const ExecuteItem.empty(4),
        const ExecuteItem(index: 5, flags: 0x11, borders: 0x200), // lower half of a tall fader
      ]).layout;
      expect(cells.map((c) => c.item.index), [0, 2]);
      expect((cells[0].width, cells[0].height), (2, 2));
      expect((cells[1].column, cells[1].width, cells[1].height), (2, 1, 1));
    });
  });

  group('crep feedback', () {
    // What MagicQ's transmitter sends, byte for byte (magic written as a
    // little-endian u32, so it reads "PERC").
    List<int> fromConsole(String text) => [
      ...'PERC'.codeUnits,
      0,
      0,
      7,
      0,
      text.length & 0xff,
      text.length >> 8,
      ...text.codeUnits,
    ];

    test('parses concatenated commands like MagicQ does', () {
      final messages = decodeCrep(fromConsole('3,75L3A1,2,50J4R2P'));
      expect(messages.map((m) => m.toString()), ['3,75L', '3A', '1,2,50J', '4R', '2P']);
    });

    test('turns commands into playback state', () {
      final update = interpretCrep(parseCrepCommands('3,75L3A1,2,50J1,4,0J4R2P'));
      expect(update.page, 2);
      final s = update.playbacks;
      expect((s[0].playback, s[0].level), (3, 75));
      expect((s[1].playback, s[1].active), (3, true));
      expect((s[2].playback, s[2].cue), (1, '2.5'));
      expect(s[3].cue, '4');
      expect((s[4].playback, s[4].active), (4, false));
    });

    test('reads the playback query reply, levels 0..256', () {
      expect(CrepCommand.queryPlaybacks(1, 10), '78,1,10H');
      final s = interpretCrep(parseCrepCommands('78,1,256,1,2,128,0,3,0,0H')).playbacks;
      expect(s.map((p) => (p.playback, p.level, p.active)), [(1, 100, true), (2, 50, false), (3, 0, false)]);
      // Other H replies (e.g. 79, encoder speeds) aren't playback state.
      expect(interpretCrep(parseCrepCommands('79,0,1,2H')).playbacks, isEmpty);
    });

    test('ignores other datagrams', () {
      expect(decodeCrep('hello world!'.codeUnits), isEmpty);
    });
  });

  group('crep', () {
    test('encodes header and playback commands', () {
      final bytes = encodeCrep(CrepCommand.level(3, 50) + CrepCommand.go(1), sequence: 5);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'CREP');
      expect(bytes[6], 5);
      expect(bytes[8] | bytes[9] << 8, bytes.length - 10);
      expect(String.fromCharCodes(bytes.sublist(10)), '3,50.0977L1G');
      expect(CrepCommand.level(2, 0), '2,0L');
      expect(CrepCommand.level(2, 100), '2,100L');
    });

    test('jump sends the cue as whole and hundredths, as MagicQ reads it', () {
      expect(CrepCommand.jump(1, '5'), '1,5,0J');
      expect(CrepCommand.jump(2, '5.5'), '2,5,50J');
      expect(CrepCommand.jump(3, '12.05'), '3,12,5J');
      // Round-trips through the feedback parser.
      final back = interpretCrep(parseCrepCommands(CrepCommand.jump(4, '7.25'))).playbacks.single;
      expect((back.playback, back.cue), (4, '7.25'));
    });

    test('levels hit every one of MagicQ\'s 257 fader steps', () {
      // MagicQ's decimal path: (int)(pct * 256 / 100), in float32.
      int magicq(String cmd) {
        final pct = double.parse(cmd.substring(cmd.indexOf(',') + 1, cmd.length - 1));
        if (pct == pct.roundToDouble()) {
          final p = pct.round();
          return p > 99 ? 256 : (p == 0 ? 0 : ((p << 8 | 0x80) ~/ 100).clamp(0, 256));
        }
        final f = Float32List.fromList([pct])[0];
        return Float32List.fromList([f * 256.0 / 100.0])[0].truncate();
      }

      for (var step = 0; step <= 256; step++) {
        expect(magicq(CrepCommand.level(1, step * 100 / 256)), step, reason: 'step $step');
      }
    });
  });
}
