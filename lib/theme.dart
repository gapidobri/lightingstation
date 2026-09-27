import 'package:flutter/widgets.dart';

/// Console palette: graphite surfaces, with colour reserved for meaning
/// (strip identity, running, flash).
abstract final class Palette {
  static const chassis = Color(0xFF16181B);
  static const panel = Color(0xFF1F2226);
  static const raised = Color(0xFF2A2E33);
  static const raisedHigh = Color(0xFF353A40);
  static const edge = Color(0xFF3A3F46);
  static const slot = Color(0xFF0E0F11);
  static const text = Color(0xFFE4E6E9);
  static const textDim = Color(0xFF8A9099);

  /// Running / active.
  static const live = Color(0xFFFFB020);
  static const flash = Color(0xFFFF5A4E);
  static const online = Color(0xFF4CD28A);

  /// Strip colours, like channel colours on a mixer.
  static const strips = [Color(0xFF4F9DFF), Color(0xFF9B7BFF), Color(0xFF2EC4B6), Color(0xFFFF8A3D), Color(0xFFFF5FA2)];

  static Color strip(int index) => strips[index % strips.length];
}

abstract final class TextStyles {
  static const _figures = [FontFeature.tabularFigures()];

  static const body = TextStyle(
    color: Palette.text,
    fontSize: 13,
    height: 1.25,
    decoration: TextDecoration.none,
    fontFeatures: _figures,
  );
  static final label = body.copyWith(fontSize: 12, fontWeight: FontWeight.w600);
  static final small = body.copyWith(fontSize: 11, color: Palette.textDim);
  static final value = body.copyWith(fontSize: 15, fontWeight: FontWeight.w600);
  static final title = body.copyWith(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.3);
}

/// Readable text colour on an arbitrary item colour.
Color onColour(Color c) => c.computeLuminance() > 0.45 ? const Color(0xFF111316) : Palette.text;
