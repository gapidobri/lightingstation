import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme.dart';

/// Key that only fires after being held for [holdTime], so a stray touch
/// can't trigger it mid-show. A ring beside the label fills from 0 to 100%
/// while held; letting go early resets it.
class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.label,
    required this.onHeld,
    this.height = 40,
    this.holdTime = const Duration(milliseconds: 800),
    this.colour = Palette.flash,
  });

  final String label;
  final VoidCallback onHeld;
  final double height;
  final Duration holdTime;
  final Color colour;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(vsync: this, duration: widget.holdTime)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onHeld();
    });

  @override
  void didUpdateWidget(HoldButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _progress.duration = widget.holdTime;
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _down() => _progress.forward(from: 0);

  void _up() {
    if (_progress.isCompleted) return;
    _progress.stop();
    _progress.animateBack(0, duration: const Duration(milliseconds: 150));
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      hint: 'Hold to activate',
      onTap: widget.onHeld,
      child: Listener(
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedBuilder(
          animation: _progress,
          builder: (context, _) {
            final t = _progress.value;
            final held = _progress.isAnimating && _progress.status == AnimationStatus.forward;
            final base = held ? Palette.raisedHigh : Palette.raised;
            return ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Container(
                height: widget.height,
                decoration: BoxDecoration(
                  color: Color.alphaBlend(widget.colour.withValues(alpha: 0.28 * t), base),
                  border: Border(
                    top: BorderSide(color: t > 0 ? widget.colour : Palette.edge, width: t > 0 ? 3 : 1),
                    bottom: const BorderSide(color: Palette.slot, width: 2),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox.square(
                      dimension: 16,
                      child: CustomPaint(
                        painter: _RingPainter(progress: t, colour: widget.colour),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyles.label.copyWith(color: t > 0 ? widget.colour : Palette.text),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Circular progress: a dim track with an arc from 12 o'clock, clockwise.
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.colour});

  final double progress;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.5;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = Palette.edge);
    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        paint
          ..color = colour
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.colour != colour;
}
