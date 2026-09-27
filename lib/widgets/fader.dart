import 'package:flutter/widgets.dart';

import '../theme.dart';

/// Vertical fader with relative drag: touching it never makes the level
/// jump, the cap moves by how far the finger moves.
class ConsoleFader extends StatefulWidget {
  const ConsoleFader({
    super.key,
    required this.value,
    required this.onChanged,
    this.colour = Palette.live,
    this.capHeight = 44,
    this.showScale = true,
    this.semanticLabel,
  });

  /// 0..1
  final double value;
  final ValueChanged<double> onChanged;
  final Color colour;
  final double capHeight;
  final bool showScale;
  final String? semanticLabel;

  @override
  State<ConsoleFader> createState() => _ConsoleFaderState();
}

class _ConsoleFaderState extends State<ConsoleFader> {
  double? _dragValue;

  double get _shown => _dragValue ?? widget.value;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final travel = (constraints.maxHeight - widget.capHeight).clamp(1.0, double.infinity);
        return Semantics(
          slider: true,
          label: widget.semanticLabel,
          value: '${(_shown * 100).round()}%',
          increasedValue: '${((widget.value + 0.05).clamp(0, 1) * 100).round()}%',
          decreasedValue: '${((widget.value - 0.05).clamp(0, 1) * 100).round()}%',
          onIncrease: () => widget.onChanged((widget.value + 0.05).clamp(0, 1)),
          onDecrease: () => widget.onChanged((widget.value - 0.05).clamp(0, 1)),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => setState(() => _dragValue = widget.value),
            onVerticalDragUpdate: (d) {
              final next = (_dragValue! - d.delta.dy / travel).clamp(0.0, 1.0);
              if (next == _dragValue) return;
              setState(() => _dragValue = next);
              widget.onChanged(next);
            },
            onVerticalDragEnd: (_) => setState(() => _dragValue = null),
            onVerticalDragCancel: () => setState(() => _dragValue = null),
            child: CustomPaint(
              size: Size.infinite,
              painter: _FaderPainter(
                value: _shown,
                colour: widget.colour,
                capHeight: widget.capHeight,
                showScale: widget.showScale,
                active: _dragValue != null,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FaderPainter extends CustomPainter {
  _FaderPainter({
    required this.value,
    required this.colour,
    required this.capHeight,
    required this.showScale,
    required this.active,
  });

  final double value;
  final Color colour;
  final double capHeight;
  final bool showScale;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final top = capHeight / 2;
    final bottom = size.height - capHeight / 2;
    final y = bottom - (bottom - top) * value;

    // Scale ticks every 10 %, longer at 0/50/100.
    if (showScale) {
      final tick = Paint()
        ..color = Palette.textDim.withValues(alpha: 0.35)
        ..strokeWidth = 1;
      for (var i = 0; i <= 10; i++) {
        final ty = bottom - (bottom - top) * i / 10;
        final len = i % 5 == 0 ? 12.0 : 6.0;
        canvas.drawLine(Offset(cx - 9 - len, ty), Offset(cx - 9, ty), tick);
        canvas.drawLine(Offset(cx + 9, ty), Offset(cx + 9 + len, ty), tick);
      }
    }

    // Slot, then the lit part below the cap.
    const slotWidth = 6.0;
    final slot = RRect.fromLTRBR(cx - slotWidth / 2, top, cx + slotWidth / 2, bottom, const Radius.circular(3));
    canvas.drawRRect(slot, Paint()..color = Palette.slot);
    canvas.drawRRect(
      RRect.fromLTRBR(cx - slotWidth / 2, y, cx + slotWidth / 2, bottom, const Radius.circular(3)),
      Paint()..color = colour.withValues(alpha: value > 0 ? 0.85 : 0),
    );

    // Cap: wide, ridged, with a centre line in the strip colour.
    final capWidth = (size.width - 16).clamp(24.0, 68.0);
    final cap = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, y), width: capWidth, height: capHeight),
      const Radius.circular(4),
    );
    canvas.drawRRect(cap.shift(const Offset(0, 3)), Paint()..color = const Color(0x99000000));
    canvas.drawRRect(
      cap,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: active
              ? const [Color(0xFF5A6068), Color(0xFF3C4148), Color(0xFF30343A)]
              : const [Color(0xFF4A4F56), Color(0xFF33373D), Color(0xFF282B30)],
          stops: const [0, 0.5, 1],
        ).createShader(cap.outerRect),
    );
    final ridge = Paint()
      ..color = const Color(0x33000000)
      ..strokeWidth = 1;
    for (final dy in [-12.0, -8.0, 8.0, 12.0]) {
      canvas.drawLine(Offset(cx - capWidth / 2 + 5, y + dy), Offset(cx + capWidth / 2 - 5, y + dy), ridge);
    }
    canvas.drawLine(
      Offset(cx - capWidth / 2 + 3, y),
      Offset(cx + capWidth / 2 - 3, y),
      Paint()
        ..color = colour
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_FaderPainter old) =>
      old.value != value || old.colour != colour || old.active != active || old.showScale != showScale;
}
