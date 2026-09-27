import 'package:flutter/widgets.dart';

import '../session.dart';
import '../theme.dart';
import 'console_button.dart';
import 'fader.dart';

/// One playback channel strip: label, Go, Pause, fader, level, Flash.
class PlaybackStrip extends StatelessWidget {
  const PlaybackStrip({super.key, required this.session, required this.index, this.compact = false});

  final ConsoleSession session;
  final int index;

  /// Phone layout: Go and Pause side by side, smaller keys.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colour = Palette.strip(index);
    final level = session.playbackLevels[index];
    final flashing = session.flashing[index];
    final cue = session.playbackCue[index];
    // Without feedback the active state is unknown, so the strip keeps its
    // colour. With feedback, inactive playbacks are dimmed like on a desk.
    final lit = !session.hasPlaybackFeedback || session.playbackActive[index];
    final scribble = lit ? colour : Color.alphaBlend(colour.withValues(alpha: 0.22), Palette.raised);
    final scribbleText = lit ? onColour(colour) : Palette.textDim;
    final keyHeight = compact ? 36.0 : 40.0;

    final go = ConsoleButton(label: 'Go', height: keyHeight, onDown: () => session.go(index));
    final pause = ConsoleButton(
      label: 'Pause',
      height: keyHeight,
      icon: compact ? pauseIcon : null,
      onDown: () => session.pause(index),
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: Palette.panel, borderRadius: BorderRadius.circular(3)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Scribble strip: playback number, and the running cue.
          Container(
            height: compact ? 30 : 34,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            color: scribble,
            child: Row(
              children: [
                Text(
                  'PB ${index + 1}',
                  maxLines: 1,
                  style: TextStyles.label.copyWith(color: scribbleText, fontSize: 13),
                ),
                if (cue != null)
                  Expanded(
                    child: Text(
                      'Q$cue',
                      maxLines: 1,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: TextStyles.label.copyWith(color: scribbleText.withValues(alpha: 0.8)),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(4, compact ? 4 : 6, 4, compact ? 4 : 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (compact)
                    Row(
                      children: [
                        Expanded(child: go),
                        const SizedBox(width: 3),
                        Expanded(child: pause),
                      ],
                    )
                  else ...[
                    go,
                    const SizedBox(height: 4),
                    pause,
                  ],
                  SizedBox(height: compact ? 4 : 8),
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}
