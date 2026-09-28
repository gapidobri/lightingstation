import 'package:flutter/widgets.dart';

import '../theme.dart';

/// Momentary hardware-style key. Fires on pointer down (not on release),
/// so it responds as fast as a physical button.
class ConsoleButton extends StatefulWidget {
  const ConsoleButton({
    super.key,
    required this.label,
    this.onDown,
    this.onUp,
    this.lit = false,
    this.litColour = Palette.live,
    this.height = 40,
    this.style,
    this.icon,
  });

  final String label;
  final VoidCallback? onDown;
  final VoidCallback? onUp;
  final bool lit;
  final Color litColour;
  final double height;
  final TextStyle? style;

  /// Drawn instead of [label] (which stays as the accessibility label).
  final WidgetBuilder? icon;

  @override
  State<ConsoleButton> createState() => _ConsoleButtonState();
}

class _ConsoleButtonState extends State<ConsoleButton> {
  bool _pressed = false;

  void _set(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
    (pressed ? widget.onDown : widget.onUp)?.call();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onDown != null || widget.onUp != null;
    final lit = widget.lit || (_pressed && widget.onUp != null);
    final base = _pressed ? Palette.raisedHigh : Palette.raised;
    return Semantics(
      button: true,
      label: widget.label,
      child: Listener(
        onPointerDown: enabled ? (_) => _set(true) : null,
        onPointerUp: enabled ? (_) => _set(false) : null,
        onPointerCancel: enabled ? (_) => _set(false) : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: widget.height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: lit ? Color.alphaBlend(widget.litColour.withValues(alpha: 0.28), base) : base,
              border: Border(
                top: BorderSide(color: lit ? widget.litColour : Palette.edge, width: lit ? 3 : 1),
                bottom: const BorderSide(color: Palette.slot, width: 2),
              ),
            ),
            child: IconTheme(
              data: IconThemeData(color: enabled ? (lit ? widget.litColour : Palette.text) : Palette.textDim),
              child:
                  widget.icon?.call(context) ??
                  Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style:
                        widget.style ??
                        TextStyles.label.copyWith(
                          color: enabled ? (lit ? widget.litColour : Palette.text) : Palette.textDim,
                        ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Painted play or pause glyph (the app has no icon font), drawn in the
/// surrounding [IconTheme] colour.
class TransportIcon extends StatelessWidget {
  const TransportIcon.play({super.key, this.size = 16}) : pause = false;
  const TransportIcon.pause({super.key, this.size = 16}) : pause = true;

  final bool pause;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colour = IconTheme.of(context).color ?? Palette.text;
    return CustomPaint(
      size: Size.square(size),
      painter: _TransportPainter(pause: pause, colour: colour),
    );
  }
}

class _TransportPainter extends CustomPainter {
  const _TransportPainter({required this.pause, required this.colour});

  final bool pause;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = colour;
    final w = size.width;
    final h = size.height;
    if (pause) {
      final bar = w * 0.3;
      canvas.drawRect(Rect.fromLTWH(w * 0.12, 0, bar, h), paint);
      canvas.drawRect(Rect.fromLTWH(w * 0.88 - bar, 0, bar, h), paint);
    } else {
      final path = Path()
        ..moveTo(w * 0.12, 0)
        ..lineTo(w * 0.95, h / 2)
        ..lineTo(w * 0.12, h)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_TransportPainter old) => old.pause != pause || old.colour != colour;
}
