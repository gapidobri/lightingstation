import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Which landscape edge holds the notch (or Dynamic Island). iOS reports equal
/// insets on both landscape edges, so the side comes from the native
/// interface orientation instead. Null where unknown (Android, desktop).
abstract final class NotchSide {
  static const _channel = MethodChannel('lightingstation/notch');
  static final ValueNotifier<AxisDirection?> side = ValueNotifier(null);

  static Future<void> init() async {
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'side') side.value = _parse(call.arguments);
    });
    try {
      side.value = _parse(await _channel.invokeMethod<String>('side'));
    } on PlatformException {
      // Falls back to the inset sizes.
    }
  }

  static AxisDirection? _parse(Object? value) => switch (value) {
    'left' => AxisDirection.left,
    'right' => AxisDirection.right,
    _ => null,
  };

  /// [padding] with only the notch's landscape edge kept. Without a known side
  /// the larger edge wins (Android reports only the cutout's edge).
  static EdgeInsets notchOnly(EdgeInsets padding, AxisDirection? side) {
    final left = switch (side) {
      AxisDirection.left => true,
      AxisDirection.right => false,
      _ => padding.left >= padding.right,
    };
    return left ? EdgeInsets.only(left: padding.left) : EdgeInsets.only(right: padding.right);
  }
}
