import 'package:flutter/widgets.dart';

import '../session.dart';
import '../theme.dart';
import 'console_button.dart';
import 'fader.dart';

/// One playback channel strip: name and cue text, Go, Pause, fader,
/// level, Flash.
///
/// Button labels come from the console: when the current cue text starts
/// with `E<pb> `, the rest of it labels Go, and when the next cue text
/// starts with `E<pb + 10> `, the rest labels Pause. Either line is then
/// hidden in the scribble strip.
class PlaybackStrip extends StatelessWidget {
  const PlaybackStrip({
    super.key,
    required this.session,
    required this.index,
    this.compact = false,
    this.showGoPause = true,
    this.showFlash = true,
    this.onOpenCues,
  });

  /// Tapping the scribble strip opens the playback's cue picker.
  final VoidCallback? onOpenCues;

  final ConsoleSession session;
  final int index;

  /// Phone layout: smaller keys and scribble strip.
  final bool compact;

  /// Hidden keys give the fader their room.
  final bool showGoPause;
  final bool showFlash;

  /// The text after `E<number> ` at the start of [line], or null if
  /// [line] doesn't start with it.
  static String? buttonLabel(String? line, int number) {
    final prefix = 'E$number ';
    if (line == null || !line.startsWith(prefix)) return null;
    return line.substring(prefix.length).trim();
  }

  /// A speed master multiplier as MagicQ writes it (`x2`, `/2`) turned
  /// into a rate (`2x`, `1/2x`).
  static String? rate(String? multiplier) {
    if (multiplier == null || multiplier.isEmpty) return null;
    if (multiplier.startsWith('x')) return '${multiplier.substring(1)}x';
    if (multiplier.startsWith('/')) return '1${multiplier}x';
    return multiplier;
  }

  @override
  Widget build(BuildContext context) {
    final colour = Palette.strip(index);
    final level = session.playbackLevels[index];
    final flashing = session.flashing[index];
    final name = session.playbackName[index];
    final cueName = session.cueName(index);
    final speedMaster = session.playbackSpeedMaster[index];
    // A speed master shows its tempo (as MagicQ writes it) in place of the
    // current cue text, and its multiplier with Running or Halted ("2x
    // Running") in place of the next cue.
    final current = speedMaster == null ? cueName : '${speedMaster.bpm.toStringAsFixed(1)} BPM';
    final next = speedMaster == null
        ? session.nextCueName(index)
        : [?rate(speedMaster.multiplier), speedMaster.halted ? 'Halted' : 'Running'].join(' ');
    final goLabel = buttonLabel(current, index + 1);
    final pauseLabel = buttonLabel(next, index + 11);
    // Without feedback the active state is unknown, so the strip keeps its
    // colour. With feedback, inactive playbacks are dimmed like on a desk.
    final lit = !session.hasPlaybackFeedback || session.playbackActive[index];
    final scribble = lit ? colour : Color.alphaBlend(colour.withValues(alpha: 0.22), Palette.raised);
    final scribbleText = lit ? onColour(colour) : Palette.textDim;
    final keyHeight = compact ? 36.0 : 40.0;

    // Press and release both matter: with native buttons, MagicQ's own
    // button handling decides what a press, hold and release do.
    // Without an E label, Go and Pause show play and pause icons.
    final goPlain = goLabel == null || goLabel.isEmpty;
    final pausePlain = pauseLabel == null || pauseLabel.isEmpty;
    final go = ConsoleButton(
      label: goPlain ? 'Go' : goLabel,
      icon: goPlain ? (_) => const TransportIcon.play() : null,
      height: keyHeight,
      onDown: () => session.setGo(index, true),
      onUp: () => session.setGo(index, false),
    );
    final pause = ConsoleButton(
      label: pausePlain ? 'Pause' : pauseLabel,
      icon: pausePlain ? (_) => const TransportIcon.pause() : null,
      height: keyHeight,
      onDown: () => session.setPause(index, true),
      onUp: () => session.setPause(index, false),
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: Palette.panel, borderRadius: BorderRadius.circular(3)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Scribble strip: the cue stack name, then the current and next
          // cue's text when known. For a speed master: tempo, then
          // multiplier and state.
          // A tap (on release, so scrolling the strips doesn't open it)
          // opens the cue picker.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpenCues,
            child: Container(
              height: compact ? 46 : 52,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              color: scribble,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Without a name (no reply from the Playbacks window yet),
                  // the number takes the main line.
                  Text(
                    name ?? 'PB ${index + 1}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyles.label.copyWith(color: scribbleText, fontSize: compact ? 12 : 13, height: 1.2),
                  ),
                  // A cue line that labels a button is hidden.
                  Text(
                    goLabel != null ? '' : current ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyles.small.copyWith(color: scribbleText.withValues(alpha: 0.85), height: 1.2),
                  ),
                  // Next cue, marked and dimmer so it reads as what's coming.
                  Text(
                    next == null || pauseLabel != null ? '' : '› $next',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyles.small.copyWith(color: scribbleText.withValues(alpha: 0.6), height: 1.2),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(4, compact ? 4 : 6, 4, compact ? 4 : 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showGoPause) ...[go, SizedBox(height: compact ? 3 : 4), pause, SizedBox(height: compact ? 4 : 8)],
                  Expanded(
                    child: ConsoleFader(
                      value: level,
                      colour: colour,
                      capHeight: compact ? 38 : 44,
                      semanticLabel: 'Playback ${index + 1} level',
                      onChanged: (v) => session.setPlaybackLevel(index, v),
                    ),
                  ),
                  SizedBox(height: compact ? 2 : 4),
                  Text(
                    '${(level * 100).round()}',
                    textAlign: TextAlign.center,
                    style: TextStyles.value.copyWith(
                      fontSize: compact ? 13 : 15,
                      color: level > 0 ? Palette.text : Palette.textDim,
                    ),
                  ),
                  if (showFlash) ...[
                    SizedBox(height: compact ? 4 : 6),
                    ConsoleButton(
                      label: 'Flash',
                      height: compact ? 44 : 52,
                      lit: flashing,
                      litColour: Palette.flash,
                      onDown: () => session.setFlash(index, true),
                      onUp: () => session.setFlash(index, false),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
