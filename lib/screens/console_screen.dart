import 'package:flutter/widgets.dart';

import '../session.dart';
import '../theme.dart';
import '../widgets/console_button.dart';
import '../widgets/execute_grid.dart';
import '../widgets/playback_strip.dart';

enum ConsoleView { playbacks, execute }

/// Phones get a denser layout: page stepper in the top bar, command line on
/// its own thin row, compact strips.
bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).shortestSide < 600;

class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key, required this.session, required this.onDisconnect});

  final ConsoleSession session;
  final VoidCallback onDisconnect;

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  ConsoleView _view = ConsoleView.playbacks;

  Widget _stepper(ConsoleSession session, {required bool compact}) {
    switch (_view) {
      case ConsoleView.playbacks:
        return _PageStepper(
          label: compact ? 'Page ${session.playbackPage}' : 'Playback page ${session.playbackPage}',
          page: session.playbackPage,
          onPage: session.selectPlaybackPage,
          compact: compact,
        );
      case ConsoleView.execute:
        final page = session.executePage;
        final number = page?.page ?? 1;
        final name = page?.name ?? '';
        return _PageStepper(
          label: compact
              ? (name.isEmpty ? 'Page $number' : name)
              : (name.isEmpty ? 'Execute page $number' : 'Execute page $number, $name'),
          page: number,
          onPage: session.selectExecutePage,
          compact: compact,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = isCompact(context);
    // Portrait phones have no room for the page stepper in the top bar.
    final stepperInBar = compact && MediaQuery.sizeOf(context).width >= 700;
    return ColoredBox(
      color: Palette.chassis,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) {
            final session = widget.session;
            final status = session.statusLines.join('   ');
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  session: session,
                  view: _view,
                  compact: compact,
                  stepper: stepperInBar ? _stepper(session, compact: true) : null,
                  onView: (v) => setState(() => _view = v),
                  onDisconnect: widget.onDisconnect,
                ),
                if (compact && status.isNotEmpty) _StatusLine(text: status),
                if (!stepperInBar)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                    child: Row(children: [_stepper(session, compact: compact)]),
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(compact ? 2 : 4, 4, compact ? 2 : 4, compact ? 2 : 6),
                    child: switch (_view) {
                      ConsoleView.playbacks => _PlaybacksView(session: session, compact: compact),
                      ConsoleView.execute => _ExecuteView(session: session),
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.session,
    required this.view,
    required this.compact,
    required this.stepper,
    required this.onView,
    required this.onDisconnect,
  });

  final ConsoleSession session;
  final ConsoleView view;
  final bool compact;
  final Widget? stepper;
  final ValueChanged<ConsoleView> onView;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final online = session.online;
    final keyHeight = compact ? 34.0 : 38.0;
    return Container(
      height: compact ? 44 : 52,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Palette.panel,
        border: Border(bottom: BorderSide(color: Palette.slot, width: 2)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(shape: BoxShape.circle, color: online ? Palette.online : Palette.flash),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? 90 : 160),
            child: Text(
              online ? session.consoleName : (compact ? 'No reply' : '${session.consoleName} (no reply)'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyles.label.copyWith(fontSize: 14),
            ),
          ),
          SizedBox(width: compact ? 8 : 16),
          for (final v in ConsoleView.values) ...[
            SizedBox(
              width: compact ? 86 : 104,
              child: ConsoleButton(
                label: v == ConsoleView.playbacks ? 'Playbacks' : 'Execute',
                height: keyHeight,
                lit: v == view,
                onDown: () => onView(v),
              ),
            ),
            const SizedBox(width: 4),
          ],
          SizedBox(width: compact ? 4 : 12),
          if (stepper != null) ...[
            Flexible(child: stepper!),
            const Spacer(),
          ] else if (compact)
            const Spacer()
          else
            // MagicQ's message and command lines.
            Expanded(
              child: Container(
                height: keyHeight,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(color: Palette.slot, borderRadius: BorderRadius.circular(3)),
                child: Text(
                  session.statusLines.join('   '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.body.copyWith(color: Palette.textDim),
                ),
              ),
            ),
          const SizedBox(width: 8),
          SizedBox(
            width: compact ? 60 : 104,
            child: ConsoleButton(label: compact ? 'Exit' : 'Disconnect', height: keyHeight, onDown: onDisconnect),
          ),
        ],
      ),
    );
  }
}

/// MagicQ's message and command lines, on phones.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      color: Palette.slot,
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyles.small),
    );
  }
}

class _PageStepper extends StatelessWidget {
  const _PageStepper({required this.label, required this.page, required this.onPage, this.compact = false});

  final String label;
  final int page;
  final ValueChanged<int> onPage;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const height = 34.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 44,
          child: ConsoleButton(label: '‹', height: height, onDown: page > 1 ? () => onPage(page - 1) : null),
        ),
        Flexible(
          child: Container(
            constraints: BoxConstraints(minWidth: compact ? 64 : 150),
            padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 12),
            alignment: Alignment.center,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyles.label.copyWith(fontSize: 14),
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: ConsoleButton(label: '›', height: height, onDown: () => onPage(page + 1)),
        ),
      ],
    );
  }
}

class _PlaybacksView extends StatelessWidget {
  const _PlaybacksView({required this.session, required this.compact});

  final ConsoleSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const minStrip = 76.0;
        final strips = [
          for (var i = 0; i < playbackCount; i++) PlaybackStrip(session: session, index: i, compact: compact),
        ];
        if (constraints.maxWidth / playbackCount >= minStrip) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final s in strips) Expanded(child: s)],
          );
        }
        // Portrait phones: scroll the strips sideways; vertical drags still
        // go to the faders.
        return ListView(
          scrollDirection: Axis.horizontal,
          children: [for (final s in strips) SizedBox(width: minStrip, child: s)],
        );
      },
    );
  }
}

class _ExecuteView extends StatelessWidget {
  const _ExecuteView({required this.session});

  final ConsoleSession session;

  @override
  Widget build(BuildContext context) {
    final page = session.executePage;
    if (page == null) {
      return Center(
        child: Text(
          'Waiting for the Execute page from the console…',
          style: TextStyles.body.copyWith(color: Palette.textDim),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep cells finger-sized; scroll sideways when the page is wider
        // than the screen.
        const minCell = 76.0;
        final grid = ExecuteGrid(session: session, page: page);
        if (page.columns == 0 || constraints.maxWidth / page.columns >= minCell) return grid;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: page.columns * minCell, height: constraints.maxHeight, child: grid),
        );
      },
    );
  }
}
