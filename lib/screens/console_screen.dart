import 'package:flutter/widgets.dart';
import 'package:magicq_remote/magicq_remote.dart';

import '../notch.dart';
import '../session.dart';
import '../theme.dart';
import '../widgets/console_button.dart';
import '../widgets/cue_picker.dart';
import '../widgets/execute_grid.dart';
import '../widgets/hold_button.dart';
import '../widgets/playback_strip.dart';

/// Split shows the playbacks on the left and the Execute grid on the
/// right, each scrolling on its own.
enum ConsoleView {
  playbacks('Playbacks'),
  execute('Execute'),
  split('Split');

  const ConsoleView(this.label);
  final String label;
}

/// Phones get a denser layout: smaller top bar keys, compact strips.
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

  /// Which playback keys the strips show; hiding them gives the faders
  /// more travel.
  bool _showGoPause = true;
  bool _showFlash = true;

  /// Split view: the playbacks pane's share of the width.
  double _split = 0.5;

  /// Playback (0-based) whose cue picker is open.
  int? _cuePicker;

  /// The top bar's page steppers: one for the current view, or one per
  /// pane in split view (playbacks first, matching the panes).
  List<Widget> _steppers(ConsoleSession session, {required bool compact}) {
    final split = _view == ConsoleView.split;
    // Split view on a phone has two steppers in the bar: shortest labels.
    final short = compact && split;
    final long = !compact && !split;
    Widget playbacks() {
      final number = session.playbackPage;
      return _PageStepper(
        label: short ? 'Pg $number' : (long ? 'Playback page $number' : 'Page $number'),
        page: number,
        onPage: session.selectPlaybackPage,
        compact: compact,
      );
    }

    Widget execute() {
      final page = session.executePage;
      final number = page?.page ?? 1;
      final name = page?.name ?? '';
      return _PageStepper(
        label: long
            ? (name.isEmpty ? 'Execute page $number' : 'Execute page $number, $name')
            : (name.isNotEmpty ? name : (short ? 'Ex $number' : 'Page $number')),
        page: number,
        onPage: session.selectExecutePage,
        compact: compact,
      );
    }

    return switch (_view) {
      ConsoleView.playbacks => [playbacks()],
      ConsoleView.execute => [execute()],
      ConsoleView.split => [playbacks(), execute()],
    };
  }

  @override
  Widget build(BuildContext context) {
    final compact = isCompact(context);
    final picker = _cuePicker;
    return Stack(
      children: [
        Positioned.fill(child: _console(context, compact: compact)),
        if (picker != null)
          Positioned.fill(
            child: CuePicker(
              key: ValueKey(picker),
              session: widget.session,
              playback: picker,
              onClose: () => setState(() => _cuePicker = null),
            ),
          ),
      ],
    );
  }

  Widget _console(BuildContext context, {required bool compact}) {
    final safe = MediaQuery.paddingOf(context);
    return ColoredBox(
      color: Palette.chassis,
      // iOS pads both landscape edges and the bottom (home indicator). The top
      // bar reaches the rounded corners, so it keeps both edges; below it only
      // the notch's edge needs the room.
      child: Padding(
        padding: EdgeInsets.only(top: safe.top),
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.session, NotchSide.side]),
          builder: (context, _) {
            final session = widget.session;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  session: session,
                  insets: EdgeInsets.only(left: safe.left, right: safe.right),
                  view: _view,
                  compact: compact,
                  steppers: _steppers(session, compact: compact),
                  showGoPause: _showGoPause,
                  showFlash: _showFlash,
                  onView: (v) => setState(() => _view = v),
                  onGoPause: () => setState(() => _showGoPause = !_showGoPause),
                  onFlash: () => setState(() => _showFlash = !_showFlash),
                  onDisconnect: widget.onDisconnect,
                ),
                Expanded(
                  child: Padding(
                    padding:
                        EdgeInsets.fromLTRB(compact ? 2 : 4, 4, compact ? 2 : 4, compact ? 2 : 6) +
                        NotchSide.notchOnly(safe, NotchSide.side.value),
                    // The insets are handled here; scroll views would add them again.
                    child: MediaQuery.removePadding(
                      context: context,
                      removeLeft: true,
                      removeTop: true,
                      removeRight: true,
                      removeBottom: true,
                      child: switch (_view) {
                        ConsoleView.playbacks => _playbacks(session, compact: compact, scroll: false),
                        ConsoleView.execute => _ExecuteView(session: session),
                        ConsoleView.split => _SplitPanes(
                          fraction: _split,
                          onChanged: (f) => setState(() => _split = f),
                          left: _playbacks(session, compact: compact, scroll: true),
                          right: _ExecuteView(session: session),
                        ),
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _playbacks(ConsoleSession session, {required bool compact, required bool scroll}) => _PlaybacksView(
    session: session,
    compact: compact,
    alwaysScroll: scroll,
    showGoPause: _showGoPause,
    showFlash: _showFlash,
    onOpenCues: (i) => setState(() => _cuePicker = i),
  );
}

/// Two panes side by side with a divider that drags left and right.
class _SplitPanes extends StatefulWidget {
  const _SplitPanes({required this.fraction, required this.onChanged, required this.left, required this.right});

  /// The left pane's share of the width, 0..1.
  final double fraction;
  final ValueChanged<double> onChanged;
  final Widget left;
  final Widget right;

  @override
  State<_SplitPanes> createState() => _SplitPanesState();
}

class _SplitPanesState extends State<_SplitPanes> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // A finger-wide grab area around a thin line.
        const handle = 16.0;
        const minPane = 120.0;
        final available = (constraints.maxWidth - handle).clamp(0.0, double.infinity);
        final lo = available <= minPane * 2 ? 0.5 : minPane / available;
        final fraction = widget.fraction.clamp(lo, 1 - lo);
        final leftWidth = available * fraction;
        final colour = _dragging ? Palette.live : Palette.edge;
        void end() => setState(() => _dragging = false);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: leftWidth, child: widget.left),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) => setState(() => _dragging = true),
                onHorizontalDragUpdate: (d) {
                  if (available == 0) return;
                  widget.onChanged(((leftWidth + d.delta.dx) / available).clamp(lo, 1 - lo));
                },
                onHorizontalDragEnd: (_) => end(),
                onHorizontalDragCancel: end,
                child: Semantics(
                  label: 'Split divider',
                  child: SizedBox(
                    width: handle,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(width: 2, color: _dragging ? Palette.live : Palette.slot),
                        // Grip, so the divider reads as draggable.
                        Container(
                          width: 6,
                          height: 40,
                          decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(3)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: widget.right),
          ],
        );
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.session,
    required this.insets,
    required this.view,
    required this.compact,
    required this.steppers,
    required this.showGoPause,
    required this.showFlash,
    required this.onView,
    required this.onGoPause,
    required this.onFlash,
    required this.onDisconnect,
  });

  final ConsoleSession session;

  /// Safe-area insets for the bar's contents; its background runs edge to edge.
  final EdgeInsets insets;
  final ConsoleView view;
  final bool compact;
  final List<Widget> steppers;
  final bool showGoPause;
  final bool showFlash;
  final ValueChanged<ConsoleView> onView;
  final VoidCallback onGoPause;
  final VoidCallback onFlash;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final online = session.online;
    final link = session.buttonLink;
    final keyHeight = compact ? 34.0 : 38.0;
    return Container(
      height: compact ? 44 : 52,
      padding: const EdgeInsets.symmetric(horizontal: 8) + insets,
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
            constraints: BoxConstraints(maxWidth: (compact ? 72 : 160) - (link != null ? 26 : 0)),
            child: Text(
              online ? session.consoleName : (compact ? 'No reply' : '${session.consoleName} (no reply)'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyles.label.copyWith(fontSize: 14),
            ),
          ),
          // Native playback buttons: lit once the console has connected back.
          if (link != null)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                'RC',
                style: TextStyles.label.copyWith(
                  color: link == RemoteLinkState.linked ? Palette.live : Palette.textDim,
                ),
              ),
            ),
          SizedBox(width: compact ? 6 : 16),
          for (final v in ConsoleView.values) ...[
            SizedBox(
              width: compact ? (v == ConsoleView.split ? 50 : 66) : 96,
              child: ConsoleButton(label: v.label, height: keyHeight, lit: v == view, onDown: () => onView(v)),
            ),
            const SizedBox(width: 4),
          ],
          SizedBox(width: compact ? 2 : 12),
          // Page steppers take the room left over, each up to a fixed
          // width so their arrows stay put as labels change.
          Expanded(
            child: Row(
              children: [
                for (final (i, stepper) in steppers.indexed) ...[
                  if (i > 0) SizedBox(width: compact ? 4 : 12),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: compact ? 220 : 420),
                      child: stepper,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: compact ? 6 : 8),
          // Strip key toggles: lit while the keys are shown.
          SizedBox(
            width: compact ? 64 : 84,
            child: ConsoleButton(label: 'Go/Pause', height: keyHeight, lit: showGoPause, onDown: onGoPause),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: compact ? 50 : 72,
            child: ConsoleButton(
              label: 'Flash',
              height: keyHeight,
              lit: showFlash,
              litColour: Palette.flash,
              onDown: onFlash,
            ),
          ),
          SizedBox(width: compact ? 6 : 16),
          // Held, not tapped, so a stray touch can't end the show's link.
          SizedBox(
            width: compact ? 56 : 112,
            child: HoldButton(label: compact ? 'Exit' : 'Disconnect', height: keyHeight, onHeld: onDisconnect),
          ),
        ],
      ),
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
    final arrow = compact ? 32.0 : 44.0;
    // Fills the width it is given, so the arrows sit at its ends.
    return Row(
      children: [
        SizedBox(
          width: arrow,
          child: ConsoleButton(label: '‹', height: height, onDown: page > 1 ? () => onPage(page - 1) : null),
        ),
        Expanded(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 12),
            alignment: Alignment.center,
            // Too narrow for the label: show just the page number.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final style = TextStyles.label.copyWith(fontSize: 14);
                final painter = TextPainter(
                  text: TextSpan(text: label, style: style),
                  maxLines: 1,
                  textDirection: TextDirection.ltr,
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout();
                final fits = painter.width <= constraints.maxWidth;
                painter.dispose();
                return Text(fits ? label : '$page', maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
              },
            ),
          ),
        ),
        SizedBox(
          width: arrow,
          child: ConsoleButton(label: '›', height: height, onDown: () => onPage(page + 1)),
        ),
      ],
    );
  }
}

class _PlaybacksView extends StatelessWidget {
  const _PlaybacksView({
    required this.session,
    required this.compact,
    this.alwaysScroll = false,
    this.showGoPause = true,
    this.showFlash = true,
    this.onOpenCues,
  });

  final ConsoleSession session;
  final bool compact;
  final ValueChanged<int>? onOpenCues;

  /// Fixed-width strips scrolling sideways, even when all would fit.
  final bool alwaysScroll;
  final bool showGoPause;
  final bool showFlash;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const minStrip = 76.0;
        final strips = [
          for (var i = 0; i < playbackCount; i++)
            PlaybackStrip(
              session: session,
              index: i,
              compact: compact,
              showGoPause: showGoPause,
              showFlash: showFlash,
              onOpenCues: onOpenCues == null ? null : () => onOpenCues!(i),
            ),
        ];
        if (!alwaysScroll && constraints.maxWidth / playbackCount >= minStrip) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final s in strips) Expanded(child: s)],
          );
        }
        // Narrow screens: scroll the strips sideways; vertical drags still
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
        // Keep cells finger-sized; scroll when the page is wider or taller
        // than the space it has.
        const minCell = 76.0;
        const minRow = 48.0;
        final grid = ExecuteGrid(session: session, page: page);
        final width = page.columns * minCell;
        final height = page.rows * minRow;
        final scrollX = width > constraints.maxWidth;
        final scrollY = height > constraints.maxHeight;
        if (!scrollX && !scrollY) return grid;
        Widget content = SizedBox(
          width: scrollX ? width : constraints.maxWidth,
          height: scrollY ? height : constraints.maxHeight,
          child: grid,
        );
        if (scrollY) content = SingleChildScrollView(child: content);
        if (scrollX) content = SingleChildScrollView(scrollDirection: Axis.horizontal, child: content);
        return content;
      },
    );
  }
}
