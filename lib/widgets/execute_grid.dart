import 'package:flutter/widgets.dart';
import 'package:magicq_remote/magicq_remote.dart';

import '../session.dart';
import '../theme.dart';
import 'fader.dart';

/// Mirrors a MagicQ Execute page: buttons fire on touch down and release
/// on touch up, fader items get a relative-drag fader. Items keep the
/// width and height (in cells) set on the console.
class ExecuteGrid extends StatelessWidget {
  const ExecuteGrid({super.key, required this.session, required this.page});

  final ConsoleSession session;
  final ExecutePage page;

  @override
  Widget build(BuildContext context) {
    if (page.columns == 0 || page.rows == 0) {
      return Center(
        child: Text(
          'Execute page ${page.page} is empty on the console. Pick another page.',
          style: TextStyles.body.copyWith(color: Palette.textDim),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 4.0;
        final w = constraints.maxWidth / page.columns;
        final h = constraints.maxHeight / page.rows;
        final layout = page.layout;
        return Stack(
          children: [
            // Region outlines sit in the gaps between items.
            if (layout.any((cell) => cell.item.hasRegionEdge))
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _RegionPainter(layout, cellWidth: w, cellHeight: h),
                  ),
                ),
              ),
            for (final cell in layout)
              Positioned(
                left: cell.column * w,
                top: cell.row * h,
                width: cell.width * w,
                height: cell.height * h,
                child: Padding(
                  padding: const EdgeInsets.all(gap / 2),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: cell.item.isFader
                        ? _FaderCell(item: cell.item, session: session)
                        : _ButtonCell(item: cell.item, session: session),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Draws each item's region edges just inside its cell, in the gap, so two
/// regions side by side read as two boxes.
class _RegionPainter extends CustomPainter {
  _RegionPainter(this.layout, {required this.cellWidth, required this.cellHeight});

  final List<ExecuteCell> layout;
  final double cellWidth;
  final double cellHeight;

  static const _stroke = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Palette.textDim;
    for (final cell in layout) {
      final item = cell.item;
      if (!item.hasRegionEdge) continue;
      final r = Rect.fromLTWH(
        cell.column * cellWidth,
        cell.row * cellHeight,
        cell.width * cellWidth,
        cell.height * cellHeight,
      );
      if (item.regionTop) canvas.drawRect(Rect.fromLTWH(r.left, r.top, r.width, _stroke), paint);
      if (item.regionBottom) canvas.drawRect(Rect.fromLTWH(r.left, r.bottom - _stroke, r.width, _stroke), paint);
      if (item.regionLeft) canvas.drawRect(Rect.fromLTWH(r.left, r.top, _stroke, r.height), paint);
      if (item.regionRight) canvas.drawRect(Rect.fromLTWH(r.right - _stroke, r.top, _stroke, r.height), paint);
    }
  }

  @override
  bool shouldRepaint(_RegionPainter old) =>
      old.cellWidth != cellWidth || old.cellHeight != cellHeight || !identical(old.layout, layout);
}

Color _itemColour(ExecuteItem item) => item.rgb != null ? Color(0xFF000000 | item.rgb!) : Palette.raised;

class _ButtonCell extends StatefulWidget {
  const _ButtonCell({required this.item, required this.session});

  final ExecuteItem item;
  final ConsoleSession session;

  @override
  State<_ButtonCell> createState() => _ButtonCellState();
}

class _ButtonCellState extends State<_ButtonCell> {
  bool _down = false;

  void _press(bool down) {
    if (_down == down) return;
    setState(() => _down = down);
    widget.session.pressExecute(widget.item.index, down: down);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (!item.exists) {
      return DecoratedBox(
        decoration: BoxDecoration(color: Palette.panel, borderRadius: BorderRadius.circular(3)),
      );
    }
    final colour = _itemColour(item);
    // Inactive items are shown as a dark cell with a colour edge, active
    // ones filled, so state reads at a glance from across the room. A
    // flash item is only on while held, and lights red like a playback's
    // Flash key.
    final flashOn = item.isFlash && (_down || item.active);
    final fill = flashOn
        ? Color.alphaBlend(Palette.flash.withValues(alpha: 0.35), Palette.raised)
        : item.active
        ? colour
        : Color.alphaBlend(colour.withValues(alpha: 0.16), Palette.raised);
    final textColour = flashOn ? Palette.flash : (item.active ? onColour(colour) : Palette.text);
    return Semantics(
      button: true,
      toggled: item.isFlash ? null : item.active,
      label: item.name,
      child: Listener(
        onPointerDown: (_) => _press(true),
        onPointerUp: (_) => _press(false),
        onPointerCancel: (_) => _press(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 60),
          decoration: BoxDecoration(
            color: _down && !flashOn ? Color.alphaBlend(const Color(0x33FFFFFF), fill) : fill,
            border: Border(
              left: BorderSide(color: colour, width: 4),
              top: flashOn ? const BorderSide(color: Palette.flash, width: 3) : BorderSide.none,
              bottom: const BorderSide(color: Palette.slot, width: 2),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The type tag ("PB", "CS", "G", ...) only shows when the
              // whole name still fits above it; otherwise the name keeps
              // all the room.
              final nameStyle = TextStyles.label.copyWith(color: textColour, fontSize: 13);
              final roomy = constraints.maxWidth >= 56 && constraints.maxHeight >= 40;
              final padding = roomy ? const EdgeInsets.fromLTRB(7, 6, 7, 6) : const EdgeInsets.fromLTRB(5, 3, 4, 3);
              final inner = constraints.deflate(padding);
              final lineHeight = 13 * nameStyle.height!;
              final painter = TextPainter(
                text: TextSpan(text: item.name, style: nameStyle),
                textDirection: TextDirection.ltr,
                textScaler: MediaQuery.textScalerOf(context),
              )..layout(maxWidth: inner.maxWidth);
              final nameHeight = painter.height;
              painter.dispose();
              const tagHeight = 14.0;
              final showTag =
                  item.tag.isNotEmpty && item.iconId != 0xfd000000 && nameHeight + tagHeight <= inner.maxHeight;
              // As many name lines as fit, so a short cell ends in an
              // ellipsis rather than a clipped line.
              final lines = ((inner.maxHeight - (showTag ? tagHeight : 0)) / lineHeight).floor().clamp(1, 6);
              return Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(item.name, maxLines: lines, overflow: TextOverflow.ellipsis, style: nameStyle),
                    ),
                    if (showTag)
                      Text(
                        item.tag,
                        maxLines: 1,
                        style: TextStyles.small.copyWith(color: textColour.withValues(alpha: 0.7)),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _FaderCell extends StatelessWidget {
  const _FaderCell({required this.item, required this.session});

  final ExecuteItem item;
  final ConsoleSession session;

  @override
  Widget build(BuildContext context) {
    final colour = item.rgb != null ? _itemColour(item) : Palette.live;
    final fader = ConsoleFader(
      value: item.level / 255,
      colour: colour,
      capHeight: 22,
      showScale: false,
      semanticLabel: item.name,
      onChanged: (v) => session.setExecuteFader(item.index, (v * 255).round()),
    );
    final name = Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyles.label);
    final value = Text('${(item.level * 100 / 255).round()}', style: TextStyles.value);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Palette.panel,
        border: Border(left: BorderSide(color: colour, width: 4)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Narrow cells (phones): name, fader and value stacked.
          if (constraints.maxWidth < 100) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyles.small),
                Expanded(child: fader),
                Text('${(item.level * 100 / 255).round()}', textAlign: TextAlign.center, style: TextStyles.label),
              ],
            );
          }
          return Row(
            children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, const Spacer(), value]),
              ),
              SizedBox(width: 44, child: fader),
            ],
          );
        },
      ),
    );
  }
}
