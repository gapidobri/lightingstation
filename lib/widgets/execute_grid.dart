import 'package:flutter/widgets.dart';
import 'package:magicq_remote/magicq_remote.dart';

import '../session.dart';
import '../theme.dart';
import 'fader.dart';

/// Mirrors a MagicQ Execute page: buttons fire on touch down and release
/// on touch up, fader items get a relative-drag fader.
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
        return Stack(
          children: [
            for (final item in page.items)
              if (!item.isFaderContinuation)
                Positioned(
                  left: (item.index % page.columns) * w,
                  top: (item.index ~/ page.columns) * h,
                  width: w,
                  height: item.isTallFader ? h * 2 : h,
                  child: Padding(
                    padding: const EdgeInsets.all(gap / 2),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: item.isFader
                          ? _FaderCell(item: item, session: session)
                          : _ButtonCell(item: item, session: session),
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }
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
    // ones filled, so state reads at a glance from across the room.
    final fill = item.active ? colour : Color.alphaBlend(colour.withValues(alpha: 0.16), Palette.raised);
    final textColour = item.active ? onColour(colour) : Palette.text;
    return Semantics(
      button: true,
      toggled: item.active,
      label: item.name,
      child: Listener(
        onPointerDown: (_) => _press(true),
        onPointerUp: (_) => _press(false),
        onPointerCancel: (_) => _press(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 60),
          padding: const EdgeInsets.fromLTRB(7, 6, 7, 6),
          decoration: BoxDecoration(
            color: _down ? Color.alphaBlend(const Color(0x33FFFFFF), fill) : fill,
            border: Border(
              left: BorderSide(color: colour, width: 4),
              bottom: const BorderSide(color: Palette.slot, width: 2),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  item.name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.label.copyWith(color: textColour, fontSize: 13),
                ),
              ),
              if (item.tag.isNotEmpty && item.iconId != 0xfd000000)
                Text(item.tag, style: TextStyles.small.copyWith(color: textColour.withValues(alpha: 0.7))),
            ],
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
