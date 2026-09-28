// Test client for native playback buttons over MagicQ remote control.
//
//   dart run example/remote_control_example.dart <console ip> <flash|go|pause> <playback> [hold ms]
//   dart run example/remote_control_example.dart <console ip> sync [seconds]
//   dart run example/remote_control_example.dart <console ip> cues <playback> [jump to cue]
//   dart run example/remote_control_example.dart <console ip> selectlag <playback>
//
// "sync" mirrors the console's screen instead, printing the playback strips
// (cue text, speed masters) and the selected window whenever they change.
// "cues" presses the playback's Select key (this changes the console's
// selected playback), prints the Cue Stack window's steps, and with a cue
// ID jumps the playback to it over CREP.
//
// Needs MagicQ's "Enable remote control" and a licence unlocked for remote
// control, and must run on a different machine from MagicQ (both use TCP
// 4911). Watch the console: the button should behave exactly like pressing
// it there, and the selected window should not change.
import 'dart:async';
import 'dart:io';

import 'package:magicq_remote/magicq_remote.dart';

Future<void> main(List<String> args) async {
  if (args.length >= 2 && args[1] == 'sync') {
    await _sync(InternetAddress(args[0]), Duration(seconds: args.length > 2 ? int.parse(args[2]) : 10));
    return;
  }
  if (args.length >= 3 && args[1] == 'selectlag') {
    await _selectLag(args[0], int.parse(args[2]));
    return;
  }
  if (args.length >= 3 && args[1] == 'cues') {
    await _cues(args[0], int.parse(args[2]), args.length > 3 ? args[3] : null);
    return;
  }
  if (args.length < 3 || !const {'flash', 'go', 'pause'}.contains(args[1])) {
    stderr.writeln('usage: remote_control_example.dart <console ip> <flash|go|pause> <playback> [hold ms]');
    stderr.writeln('       remote_control_example.dart <console ip> sync [seconds]');
    stderr.writeln('       remote_control_example.dart <console ip> cues <playback> [jump to cue]');
    exitCode = 64;
    return;
  }
  final console = InternetAddress(args[0]);
  final playback = int.parse(args[2]);
  final hold = Duration(milliseconds: args.length > 3 ? int.parse(args[3]) : 300);
  final index = switch (args[1]) {
    'flash' => ChmqButtons.flash(playback),
    'go' => ChmqButtons.go(playback),
    _ => ChmqButtons.pause(playback),
  };

  final remote = await MagicQRemoteControl.start(console, name: 'RC test');
  print('Asked ${console.address} to connect back on TCP $chmqCommsPort...');
  try {
    await remote.states.firstWhere((s) => s == RemoteLinkState.linked).timeout(const Duration(seconds: 5));
  } on TimeoutException {
    print('No link. Check "Enable remote control" on the console, and that nothing blocks TCP $chmqCommsPort here.');
    await remote.close();
    exitCode = 1;
    return;
  }
  print('Linked. Pressing ${args[1]} $playback (board button $index) for ${hold.inMilliseconds} ms.');
  remote.setButton(index, pressed: true);
  await Future<void>.delayed(hold);
  remote.setButton(index, pressed: false);
  // Keep the link up briefly so the release is delivered before hanging up.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await remote.close();
  print('Done. If nothing happened, look for "Remote request - not unlocked" on the console.');
}

Future<void> _sync(InternetAddress console, Duration duration) async {
  final remote = await MagicQRemoteControl.start(console, name: 'RC test', screenSync: true);
  final last = <int, String>{};
  int? window;
  var strips = 0;
  remote.playbackStrips.listen((strip) {
    strips++;
    final text = '$strip${strip.speedMaster == null ? '' : '  -> ${strip.speedMaster}'}';
    if (last[strip.playback] != text) print(last[strip.playback] = text);
  });
  remote.statuses.listen((status) {
    if (status.selectedWindow != window) print('selected window: ${window = status.selectedWindow}');
  });
  try {
    await remote.states.firstWhere((s) => s == RemoteLinkState.linked).timeout(const Duration(seconds: 5));
  } on TimeoutException {
    print('No link. Check "Enable remote control" on the console.');
    await remote.close();
    exitCode = 1;
    return;
  }
  print('Linked, mirroring for ${duration.inSeconds} s.');
  await Future<void>.delayed(duration);
  print('$strips strip messages.');
  await remote.close();
}

/// Presses [playback]'s Select key, then asks for the Cue Stack window's
/// header every 50 ms for 3 s and prints each title change, to show how
/// long MagicQ takes to switch the window to the selected stack.
Future<void> _selectLag(String host, int playback) async {
  final client = await MagicQClient.connect(host);
  final remote = await MagicQRemoteControl.start(client.console, name: 'RC test');
  try {
    await remote.states.firstWhere((s) => s == RemoteLinkState.linked).timeout(const Duration(seconds: 5));
    final clock = Stopwatch();
    String? last;
    final sub = client.windowHeaders.where((h) => h.window == MagicQWindow.cueStack).listen((h) {
      if (h.title == last) return;
      last = h.title;
      print('${clock.isRunning ? '${clock.elapsedMilliseconds} ms' : 'before'}: ${h.title}');
    });
    client.requestWindow(MagicQWindow.cueStack, count: 1);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    print('Linked. Selecting playback $playback.');
    final select = ChmqButtons.select(playback);
    clock.start();
    remote.setButton(select, pressed: true);
    remote.setButton(select, pressed: false);
    while (clock.elapsedMilliseconds < 3000) {
      client.requestWindow(MagicQWindow.cueStack, count: 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await sub.cancel();
  } on TimeoutException {
    print('No link. Check "Enable remote control" on the console.');
    exitCode = 1;
  } finally {
    await remote.close();
    client.close();
  }
}

Future<void> _cues(String host, int playback, String? jump) async {
  final client = await MagicQClient.connect(host);
  final remote = await MagicQRemoteControl.start(client.console, name: 'RC test');
  try {
    await remote.states.firstWhere((s) => s == RemoteLinkState.linked).timeout(const Duration(seconds: 5));
    print('Linked. Selecting playback $playback.');
    final select = ChmqButtons.select(playback);
    // As the app does: MagicQ switches the Cue Stack window ~0.85 s after
    // the press, so wait for its title to change. Waits the full 3 s when
    // the playback was already selected.
    final before = await client.waitForCueStackTitle((_) => true);
    final clock = Stopwatch()..start();
    remote.setButton(select, pressed: true);
    remote.setButton(select, pressed: false);
    try {
      await client.waitForCueStackTitle((t) => t != before, timeout: const Duration(seconds: 3));
    } on TimeoutException {
      print('Title unchanged after 3 s (already selected?): $before');
    }
    final requested = clock.elapsedMilliseconds;
    int? firstPartial;
    final stack = await client.readCueStack(
      onProgress: (partial) {
        firstPartial ??= clock.elapsedMilliseconds;
        print('  ${clock.elapsedMilliseconds} ms: ${partial.steps.length} steps so far');
      },
    );
    print(
      'Request sent $requested ms, first cues ${firstPartial ?? '-'} ms, complete ${clock.elapsedMilliseconds} ms.',
    );
    print('${stack.title}: ${stack.steps.length} steps');
    stack.steps.forEach(print);
    if (jump != null) {
      print('Jumping playback $playback to cue $jump: ${CrepCommand.jump(playback, jump)}');
      client.sendCrep(CrepCommand.jump(playback, jump));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  } on TimeoutException {
    print('No link or no reply. Check "Enable remote control" and "Enable remote app" on the console.');
    exitCode = 1;
  } finally {
    await remote.close();
    client.close();
  }
}
