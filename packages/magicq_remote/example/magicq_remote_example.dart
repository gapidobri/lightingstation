// Discovers consoles, or connects to one and prints its Execute page.
//
//   dart run example/magicq_remote_example.dart            # discover
//   dart run example/magicq_remote_example.dart 10.0.0.5   # dump page
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
