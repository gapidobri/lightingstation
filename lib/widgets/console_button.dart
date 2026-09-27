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

/// Two vertical bars, for narrow Pause keys.
Widget pauseIcon(BuildContext context) {
  final colour = IconTheme.of(context).color ?? Palette.text;
  final bar = Container(width: 3, height: 12, color: colour);
  return Row(mainAxisSize: MainAxisSize.min, children: [bar, const SizedBox(width: 3), bar]);
}
