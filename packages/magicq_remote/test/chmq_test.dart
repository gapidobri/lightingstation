import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:magicq_remote/magicq_remote.dart';
import 'package:test/test.dart';

/// MagicQ's input decoder, transcribed expression by expression from
/// `FUN_100482080`, as an independent check of [encodeChmqInput].
({int subtype, int a, int b, int mods, int window}) referenceDecode(List<int> p) {
  const k = [
    0x69, 0x1c, 0x38, 0xe9, 0x87, 0xcb, 0x37, 0x19, 0x38, 0xa3, //
    0x0b, 0x57, 0xab, 0x33, 0x9e, 0x29, 0x52, 0x19, 0xf8, 0x27,
  ];
  final subtype = (k[0x0b] ^ p[0x14]) << 8 | (k[0x10] ^ p[0x0f]);
  final local34 = k[0] ^ p[0x1f];
  final local33 = k[1] ^ p[0x1e];
  final bVar13 = k[3] ^ p[0x1c];
  final local32 = k[8] ^ p[0x17];
  final bVar3 = k[0x0d] ^ p[0x12];
  final bVar4 = k[0x0e] ^ p[0x11];
  final uVar22 = k[6] ^ p[0x19];
  final uVar20 = k[9] ^ p[0x16];
  final local31 = k[0x13] ^ p[0x0c];
  final uVar18 = k[0x11] ^ p[0x0e];
  final uVar8 = k[2] ^ p[0x1d];
  final uVar24 = k[5] ^ p[0x1a];
  final uVar9 = k[0x0f] ^ p[0x10];
  final uVar19 = k[4] ^ p[0x1b];
  final uVar14 = (k[7] ^ p[0x18]) << 8;
  final uVar15 = (k[0x0a] ^ p[0x15]) << 8;
  final uVar16 = (k[0x0c] ^ p[0x13]) << 8;
  final uVar21 = (k[0x12] ^ p[0x0d]) << 8;
  final a =
      local34 << 8 & 0x8000 |
      local31 << 8 & 0x4000 |
      local33 << 8 & 0x2000 |
      uVar21 & 0x1000 |
      uVar16 & 0x800 |
      local32 << 8 & 0x400 |
      uVar15 & 0x200 |
      uVar14 & 0x100 |
      uVar19 & 0xffffff80 |
      uVar9 & 0x40 |
      bVar13 & 0x20 |
      uVar24 & 0x10 |
      uVar8 & 8 |
      uVar18 & 4 |
      uVar20 & 2 |
      uVar22 & 1;
  final u24 = bVar13 & 0x40 | uVar24 & 0x20 | uVar8 & 0x10 | uVar18 & 8 | uVar20 & 4 | uVar22 & 2;
  final u22 = uVar21 & 0x2000 | uVar16 & 0x1000 | local32 << 8 & 0x800 | uVar15 & 0x400 | uVar14 & 0x200 | uVar19 & 1;
  final u19 = local34 << 8 & 0x100 | local31 << 8 & 0x8000 | local33 << 8 & 0x4000;
  final b = u19 | u22 | uVar9 & 0xff80 | u24;
  return (subtype: subtype, a: a, b: b, mods: bVar3 << 8 | bVar4, window: p[0x0a] | p[0x0b] << 8);
}

void main() {
  group('frames', () {
    test('header: magic, version, length, type', () {
      final f = encodeChmq(0x10, List.filled(22, 0));
      expect(f.sublist(0, 4), 'CHMQ'.codeUnits);
      expect(f[4], 0x1b);
      expect(f[5], 0);
      expect(f[6] | f[7] << 8, 32);
      expect(f[8] | f[9] << 8, 0x10);
      final parsed = parseChmqFrame(f)!;
      expect(parsed.type, 0x10);
      expect(parsed.length, 32);
    });

    test('rejects other data and short headers', () {
      expect(parseChmqFrame('CHWP000000'.codeUnits), isNull);
      expect(parseChmqFrame([0x43, 0x48, 0x4d]), isNull);
    });

    test('link request is 28 bytes with flags and name', () {
      final r = chmqLinkRequest(name: 'Phone');
      expect(r.length, 28);
      expect(parseChmqFrame(r)!.length, 28);
      // MagicQ ignores requests of type 0x16.
      expect(parseChmqFrame(r)!.type, isNot(0x16));
      expect(r[10] | r[11] << 8, ChmqLinkFlags.inputOnly);
      expect(String.fromCharCodes(r.sublist(12, 17)), 'Phone');
      expect(r[27], 0);
      expect(chmqLinkRequest(name: 'A very long console name')[27], 0, reason: 'name stays terminated');
    });

    test('hello asks for a reply unless told not to', () {
      expect(chmqHello()[10] & 1, 0);
      expect(chmqHello(wantReply: false)[10] & 1, 1);
      expect(parseChmqFrame(chmqHello())!.type, ChmqType.hello);
    });
  });

  group('input', () {
    test('MagicQ decodes exactly what is encoded', () {
      final rnd = Random(7);
      for (var i = 0; i < 2000; i++) {
        final m = ChmqInputMessage(
          window: 1 + rnd.nextInt(0x2e3),
          subtype: rnd.nextInt(10),
          a: rnd.nextInt(0x10000),
          b: rnd.nextInt(0x10000),
          mods: rnd.nextInt(0x10000),
        );
        final frame = encodeChmqInput(m, random: rnd);
        expect(frame.length, 0x20);
        final r = referenceDecode(frame);
        expect((r.window, r.subtype, r.a, r.b, r.mods), (m.window, m.subtype, m.a, m.b, m.mods));
        expect(decodeChmqInput(frame), m);
      }
    });

    test('filler is random, so equal messages differ on the wire', () {
      const m = ChmqInputMessage(window: 1, subtype: 4, a: 3, b: 1);
      expect(encodeChmqInput(m, random: Random(1)), isNot(encodeChmqInput(m, random: Random(2))));
    });

    test('buttons use the board-button subtype, which selects no window', () {
      final r = decodeChmqInput(chmqButton(ChmqButtons.go(3), pressed: true))!;
      expect(r.subtype, ChmqInput.button);
      expect(r.a, 22);
      expect(r.b, 1);
      expect(r.window, inInclusiveRange(1, 0x2e3));
      expect(decodeChmqInput(chmqButton(0, pressed: false))!.b, 0);
    });

    test('playback buttons map to keycodes 0x100 + index', () {
      expect(ChmqButtons.flash(1), 0);
      expect(ChmqButtons.flash(10), 9);
      expect(ChmqButtons.pause(1), 10);
      expect(ChmqButtons.go(1), 20);
      expect(ChmqButtons.go(10), 29);
      expect(ChmqButtons.select(1), 39);
      expect(() => ChmqButtons.go(11), throwsRangeError);
    });
  });

  group('MagicQRemoteControl', () {
    // A fake console on loopback: listens for the UDP link request, then
    // connects back like MagicQ does. Ports are free ones picked per test.
    test('links when the console connects back, then delivers buttons', () async {
      final console = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final commsPort = await _freeTcpPort();
      final requests = StreamController<Datagram>();
      console.listen((e) {
        final d = console.receive();
        if (e == RawSocketEvent.read && d != null) requests.add(d);
      });

      final remote = await MagicQRemoteControl.start(
        InternetAddress.loopbackIPv4,
        commsPort: commsPort,
        requestPort: console.port,
      );
      final request = await requests.stream.first.timeout(const Duration(seconds: 2));
      expect(parseChmqFrame(request.data)!.length, 28);
      expect(remote.isLinked, isFalse);
      expect(remote.flash(1, down: true), isFalse, reason: 'nothing to send on');

      final linked = remote.states.firstWhere((s) => s == RemoteLinkState.linked);
      final link = await Socket.connect(InternetAddress.loopbackIPv4, commsPort);
      final received = <int>[];
      final gotFrames = Completer<void>();
      final hungUp = Completer<void>();
      link.listen((bytes) {
        received.addAll(bytes);
        if (_frames(received).any((f) => parseChmqFrame(f)!.type == ChmqType.input)) {
          if (!gotFrames.isCompleted) gotFrames.complete();
        }
      }, onDone: hungUp.complete);
      await linked.timeout(const Duration(seconds: 2));

      expect(remote.go(4, down: true), isTrue);
      await gotFrames.future.timeout(const Duration(seconds: 2));
      final frames = _frames(received);
      expect(frames.first.sublist(8, 10), [ChmqType.hello, 0], reason: 'hello first, so MagicQ learns our version');
      final input = frames.map(decodeChmqInput).whereType<ChmqInputMessage>().single;
      expect((input.subtype, input.a, input.b), (ChmqInput.button, ChmqButtons.go(4), 1));

      // Closing releases held buttons before hanging up.
      await remote.close();
      await hungUp.future.timeout(const Duration(seconds: 2));
      final last = _frames(received).map(decodeChmqInput).whereType<ChmqInputMessage>().last;
      expect((last.a, last.b), (ChmqButtons.go(4), 0));

      link.destroy();
      console.close();
      await requests.close();
    });

    test('with screen sync, asks for the screen and reads strips and status', () async {
      final console = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final commsPort = await _freeTcpPort();
      final requests = StreamController<Datagram>();
      console.listen((e) {
        final d = console.receive();
        if (e == RawSocketEvent.read && d != null) requests.add(d);
      });
      final remote = await MagicQRemoteControl.start(
        InternetAddress.loopbackIPv4,
        commsPort: commsPort,
        requestPort: console.port,
        screenSync: true,
      );
      final request = await requests.stream.first.timeout(const Duration(seconds: 2));
      expect(request.data.sublist(10, 12), [ChmqLinkFlags.screenSync, 0]);

      final link = await Socket.connect(InternetAddress.loopbackIPv4, commsPort);
      final received = <int>[];
      final asked = Completer<void>();
      link.listen((bytes) {
        received.addAll(bytes);
        if (_frames(received).any((f) => parseChmqFrame(f)!.type == ChmqType.linkFlags) && !asked.isCompleted) {
          asked.complete();
        }
      });
      await asked.future.timeout(const Duration(seconds: 2));

      final strip = remote.playbackStrips.first;
      final status = remote.statuses.first;
      // Status and a strip, the strip split across two writes.
      final stripFrame = encodeChmq(ChmqType.widget, [
        0x35, 0x01, 2, 0, 0x6a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0x11, 0, //
        ...'PB10 SP2\x00Int SPM\x00127.9 BPM\x00^\x00x2 Running\x00'.codeUnits,
      ]);
      link.add(encodeChmq(ChmqType.status, [3, 0, 0, 0, 0, 0, 0x1b, 0, 0, 0]));
      link.add(stripFrame.sublist(0, 20));
      await link.flush();
      link.add(stripFrame.sublist(20));
      expect((await status.timeout(const Duration(seconds: 2))).selectedWindow, 0x1b);
      expect(remote.selectedWindow, 0x1b);
      final got = await strip.timeout(const Duration(seconds: 2));
      expect(got.speedMaster, const SpeedMasterInfo(number: 2, bpm: 127.9, multiplier: 'x2'));

      await remote.close();
      link.destroy();
      console.close();
      await requests.close();
    });

    test('drops connections from other addresses', () async {
      final commsPort = await _freeTcpPort();
      final remote = await MagicQRemoteControl.start(
        InternetAddress('192.0.2.1'),
        commsPort: commsPort,
        requestPort: 9,
      );
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, commsPort);
      await socket.drain<void>().timeout(const Duration(seconds: 2));
      expect(remote.isLinked, isFalse);
      socket.destroy();
      await remote.close();
    });
  });
}

Future<int> _freeTcpPort() async {
  final s = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Splits a received stream into complete CHMQ frames.
List<Uint8List> _frames(List<int> bytes) {
  final out = <Uint8List>[];
  var i = 0;
  while (i < bytes.length) {
    final f = parseChmqFrame(bytes.sublist(i));
    if (f == null || i + f.length > bytes.length) break;
    out.add(Uint8List.fromList(bytes.sublist(i, i + f.length)));
    i += f.length;
  }
  return out;
}
