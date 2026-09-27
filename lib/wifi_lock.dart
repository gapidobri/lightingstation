import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps the phone's Wi-Fi out of power saving while connected to a
/// console, so fader updates aren't delivered in clumps. Android only; iOS
/// has no equivalent API.
abstract final class WifiLock {
  static const _channel = MethodChannel('lightingstation/wifi');

  static Future<void> acquire() => _call('acquire');
  static Future<void> release() => _call('release');

  static Future<void> _call(String method) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // Best effort: the app works without it, just less smoothly on Wi-Fi.
    }
  }
}
