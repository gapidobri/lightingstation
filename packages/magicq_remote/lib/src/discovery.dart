import 'dart:async';
import 'dart:io';

import 'chwp/messages.dart';
import 'chwp/transport.dart';

/// Broadcasts a CHWP info query and collects the consoles that answer.
///
/// Needs "Enable remote app" on each console. On iOS, broadcasting also
/// needs the multicast networking entitlement.
Future<List<ConsoleInfo>> discoverConsoles({
  Duration timeout = const Duration(seconds: 2),
  InternetAddress? broadcast,
}) async {
  final transport = await ChwpTransport.acquire();
  final found = <String, ConsoleInfo>{};
  final sub = transport.packets.listen((d) {
    if (d.packet.type != ChwpType.infoReply) return;
    final address = d.from.address;
    found[address] = ConsoleInfo.parse(address, d.packet.payload);
  });
  final target = broadcast ?? InternetAddress('255.255.255.255');
  try {
    for (var i = 0; i < 3; i++) {
      transport.send(target, ChwpType.info, ChwpRequests.info());
      await Future<void>.delayed(timeout ~/ 3);
    }
  } finally {
    await sub.cancel();
    transport.release();
  }
  return found.values.toList();
}
