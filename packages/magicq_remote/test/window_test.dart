import 'dart:convert';
import 'dart:typed_data';

import 'package:magicq_remote/magicq_remote.dart';
import 'package:test/test.dart';

/// Builds a 0x8007 item as `FUN_100543d60` writes it.
List<int> item(int index, String text, String name, String detail, {int flags = 1, int state = 2}) {
  final strings = [...latin1.encode(text), 0, ...latin1.encode(name), 0, ...latin1.encode(detail), 0];
  final w = PayloadWriter()
    ..u16(index)
    ..u16(16 + strings.length)
    ..u16(0)
    ..u16(flags)
    ..u32(0)
    ..u32(state);
  return [...w.toBytes(), ...strings];
}

Uint8List chunk(int window, int page, List<List<int>> items) {
  final w = PayloadWriter()
    ..u16(window | page << 8)
    ..u16(items.length);
  return Uint8List.fromList([...w.toBytes(), for (final i in items) ...i]);
}

void main() {
  test('window request payload', () {
    expect(ChwpRequests.window(MagicQWindow.playbacks, count: 128), [0, 0, 0x11, 0, 0, 0, 128, 0]);
  });

  test('parses window header', () {
    final w = PayloadWriter()
      ..u16(0x11)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..u32(12)
      ..u32(6)
      ..u32(0)
      ..u16(9);
    final bytes = Uint8List.fromList([...w.toBytes(), ...latin1.encode('Playbacks'), 0]);
    final info = WindowInfo.parse(bytes);
    expect(info.window, 0x11);
    expect(info.items, 12);
    expect(info.columns, 6);
    expect(info.title, 'Playbacks');
  });

  test('reads cue stack steps by column header', () {
    final reader = CueStackReader()
      ..header(WindowInfo(window: MagicQWindow.cueStack, view: 0, items: 12, columns: 3, title: 'Cue Stack'))
      ..columns(WindowColumns(window: MagicQWindow.cueStack, names: ['', 'Cue id', 'Cue text']))
      ..add(
        WindowItemsChunk.parse(
          chunk(MagicQWindow.cueStack, 0, [
            item(0, '> ', '', ''),
            item(1, '1.00', '', ''),
            item(2, 'Walk in', '', ''),
            item(3, '', '', ''),
            item(4, '2.50', '', ''),
            item(5, '', '', ''),
            item(6, 'End (0.00s)', '', ''),
            item(7, '', '', '', flags: 0x20),
            item(8, '', '', '', flags: 0x20),
          ]),
        ),
      )
      // Other windows' replies are ignored.
      ..add(WindowItemsChunk.parse(chunk(0x11, 0, [item(7, '9.00', '', '')])));
    expect(reader.title, 'Cue Stack');
    expect(reader.steps!.map((s) => (s.step, s.cue, s.text)), [(0, '1', 'Walk in'), (1, '2.5', '')]);
  });

  test('cue stack reader needs a cue id column', () {
    final reader = CueStackReader()
      ..header(WindowInfo(window: MagicQWindow.cueStack, view: 1, items: 4, columns: 2))
      ..columns(WindowColumns(window: MagicQWindow.cueStack, names: ['Fader action', 'Value']));
    expect(reader.steps, isNull);
  });

  test('parses items and reads playback names and cues', () {
    final c = WindowItemsChunk.parse(
      chunk(0x11, 1, [
        item(0, '', 'Main', '', flags: 0x21),
        item(1, 'PB1', 'Front wash', '5.50', state: 1),
        item(2, 'PB2 T', 'CS2', '12'),
        item(3, 'PB10 DEF', 'Haze', '1.00', state: 1),
        item(4, 'W1-1', 'Wing stack', '3.00'),
      ]),
    );
    expect(c.window, 0x11);
    expect(c.page, 1);
    expect(c.items.map((i) => i.index), [0, 1, 2, 3, 4]);

    final infos = c.items.map(PlaybackInfo.fromItem).whereType<PlaybackInfo>().toList();
    expect(infos.map((i) => i.playback), [1, 2, 10]);
    expect(infos.map((i) => i.name), ['Front wash', 'CS2', 'Haze']);
    // An inactive playback reports its cue count, not a cue.
    expect(infos.map((i) => i.cue), ['5.5', null, '1']);
  });

  test('ignores stale padding after the last item', () {
    final bytes = chunk(0x11, 0, [item(1, 'PB1', 'Front', '2.00')]);
    final padded = Uint8List.fromList([...bytes, ...item(9, 'PB9', 'Stale', '1.00')]);
    expect(WindowItemsChunk.parse(padded).items.length, 1);
  });

  group('status view', () {
    WindowInfo header({int view = PlaybackWindowView.status, int columns = 3}) =>
        WindowInfo(window: 0x11, view: view, items: columns * 2, columns: columns);

    test('reads current and next cue from the cell below each label', () {
      final reader = PlaybackWindowReader()..header(header());
      final infos = reader.add(
        WindowItemsChunk.parse(
          chunk(0x11, 0, [
            item(0, 'PB1', 'Front wash', '(3) '),
            item(1, 'PB2 SP1', 'Chase', 'ACT '),
            item(2, 'PB3', 'CS3', ''),
            item(3, 'Blackout', 'Walk in', ''),
            item(4, '2.50', '3.00', ''),
            item(5, '1.00 Intro', '', ''),
          ]),
        ),
      );
      expect(infos.map((i) => i.playback), [1, 2, 3]);
      expect(infos.map((i) => i.name), ['Front wash', 'Chase', 'CS3']);
      expect(infos.map((i) => i.cueName), ['Blackout', null, 'Intro']);
      expect(infos.map((i) => i.cue), [null, '2.5', '1']);
      expect(infos.map((i) => i.nextCue), ['Walk in', '3.00', null]);
    });

    test('pairs cells that arrive in separate datagrams', () {
      final reader = PlaybackWindowReader()..header(header(columns: 1));
      expect(reader.add(WindowItemsChunk.parse(chunk(0x11, 0, [item(0, 'PB4', 'Movers', '')]))).single.cueName, null);
      final info = reader.add(WindowItemsChunk.parse(chunk(0x11, 0, [item(1, 'Sweep', '', '')]))).single;
      expect(info.playback, 4);
      expect(info.cueName, 'Sweep');
    });

    test('ignores the fader or Flash cell under upper-bank labels', () {
      final reader = PlaybackWindowReader()..header(header(columns: 2));
      final infos = reader.add(
        WindowItemsChunk.parse(
          chunk(0x11, 0, [
            item(0, 'PB16', 'Upper', ''),
            item(1, 'PB17', 'Upper 2', ''),
            item(2, '', '', '', flags: 0x8001),
            item(3, '', 'FL', '', flags: 0x81),
          ]),
        ),
      );
      expect(infos.map((i) => i.name), ['Upper', 'Upper 2']);
      expect(infos.every((i) => i.cueName == null && i.nextCue == null), isTrue);
    });

    test('falls back to the standard view parser', () {
      final reader = PlaybackWindowReader()..header(header(view: PlaybackWindowView.standard));
      final info = reader.add(WindowItemsChunk.parse(chunk(0x11, 0, [item(1, 'PB1', 'Front', '5.50')]))).single;
      expect(info.cue, '5.5');
      expect(info.cueName, null);
    });
  });

  test('parses column headers', () {
    final w = PayloadWriter()
      ..u16(MagicQWindow.cueStack)
      ..u16(3)
      ..cString('Cue id')
      ..cString('Cue text')
      ..cString('Wait');
    final c = WindowColumns.parse(w.toBytes());
    expect(c.window, MagicQWindow.cueStack);
    expect(c.names, ['Cue id', 'Cue text', 'Wait']);
  });
}
