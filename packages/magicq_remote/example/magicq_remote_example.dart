// Discovers consoles, or connects to one and prints its Execute page.
//
//   dart run example/magicq_remote_example.dart            # discover
//   dart run example/magicq_remote_example.dart 10.0.0.5   # dump page
//   dart run example/magicq_remote_example.dart 10.0.0.5 window 17  # dump a window (17 = Playbacks)
//
// Must run on a different machine than MagicQ (both need UDP port 4920).
import 'dart:io';

import 'package:magicq_remote/magicq_remote.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    final consoles = await discoverConsoles();
    if (consoles.isEmpty) stdout.writeln('No consoles found.');
    consoles.forEach(stdout.writeln);
    return;
  }

  final client = await MagicQClient.connect(args.first);
  stdout.writeln('Connected to "${client.consoleName}"');
  client.status.listen((s) => stdout.writeln('status: ${s.lines.join(' | ')}'));
  if (args.length >= 3 && args[1] == 'window') {
    await dumpWindow(client, int.parse(args[2]));
    client.close();
    return;
  }
  final page = await client.executePages.first;
  stdout.writeln(
    'Execute page ${page.page} "${page.name}" '
    '${page.columns}x${page.rows}',
  );
  for (final item in page.items.where((i) => i.exists)) {
    stdout.writeln(
      '  #${item.index} ${item.name} [${item.tag}] '
      'active=${item.active} fader=${item.isFader} level=${item.level}',
    );
  }
  client.close();
}

/// Prints one window's header and cells, and what the app reads from it.
Future<void> dumpWindow(MagicQClient client, int window) async {
  final reader = PlaybackWindowReader();
  client.windowHeaders.where((h) => h.window == window).listen((h) {
    reader.header(h);
    stdout.writeln(
      'window ${h.window} "${h.title}" view=${h.view} items=${h.items} '
      'columns=${h.columns}',
    );
  });
  client.windowItems.where((c) => c.window == window).listen((c) {
    for (final i in c.items) {
      stdout.writeln(
        '  #${i.index} flags=0x${i.flags.toRadixString(16)} '
        'state=${i.state} "${i.text}" "${i.name}" "${i.detail}"',
      );
    }
    if (window != MagicQWindow.playbacks) return;
    for (final p in reader.add(c)) {
      stdout.writeln(
        '  -> PB${p.playback} "${p.name}" cue=${p.cue} '
        'cueName=${p.cueName} next=${p.nextCue}',
      );
    }
  });
  client.requestWindow(window);
  await Future<void>.delayed(const Duration(seconds: 2));
}
