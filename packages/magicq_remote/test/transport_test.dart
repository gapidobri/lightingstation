import 'dart:io';

import 'package:magicq_remote/magicq_remote.dart';
import 'package:test/test.dart';

void main() {
  // An unused port; the real one (4920) may belong to a local MagicQ.
  const port = 49201;

  test('a second plain bind of the port fails on BSD sockets (the iOS bug)', () async {
    final first = await ChwpTransport.bind(port: port);
    addTearDown(first.close);
    if (!(Platform.isMacOS || Platform.isIOS)) return;
    await expectLater(
      ChwpTransport.bind(port: port),
      throwsA(isA<SocketException>().having(isAddressInUse, 'is address in use', isTrue)),
    );
  });

  test('discovery and a connection share one socket', () async {
    final results = await Future.wait([ChwpTransport.acquire(port: port), ChwpTransport.acquire(port: port)]);
    expect(identical(results[0], results[1]), isTrue);

    results[0].release();
    // Still open for the other user: sending must not throw.
    results[1].send(InternetAddress.loopbackIPv4, ChwpType.info);
    results[1].release();

    // Closed with the last user, so the port can be bound again.
    final again = await ChwpTransport.bind(port: port);
    again.close();
  });
}
