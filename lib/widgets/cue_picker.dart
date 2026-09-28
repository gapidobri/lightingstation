import 'package:flutter/widgets.dart';
import 'package:magicq_remote/magicq_remote.dart';

import '../session.dart';
import '../theme.dart';
import 'console_button.dart';

/// A playback's cue list over the console screen. Tapping a cue jumps the
/// playback to it with the cue's own times, then closes the picker.
///
/// Rows fire on tap release, not on pointer down like the console keys, so
/// scrolling the list can't jump a cue.
class CuePicker extends StatefulWidget {
  const CuePicker({super.key, required this.session, required this.playback, required this.onClose});

  final ConsoleSession session;

  /// 0-based.
  final int playback;
  final VoidCallback onClose;

  @override
  State<CuePicker> createState() => _CuePickerState();
}

class _CuePickerState extends State<CuePicker> {
  /// The list on show: the cached one from an earlier opening until the
  /// fresh read arrives.
  CueList? _cues;
  Object? _error;
  bool _loading = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _cues = widget.session.cachedCues(widget.playback);
    _reload();
  }

  Future<void> _reload() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cues = await widget.session.loadCues(
        widget.playback,
        onProgress: (partial) {
          if (!mounted || request != _request) return;
          // Don't shrink a cached list while its refresh is still arriving.
          final shown = _cues;
          if (shown != null && partial.steps.length < shown.steps.length) return;
          setState(() => _cues = partial);
        },
      );
      if (!mounted || request != _request) return;
      setState(() => _cues = cues);
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _error = e);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _jump(String cue) {
    widget.session.jumpToCue(widget.playback, cue);
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).shortestSide < 600;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: const ColoredBox(color: Color(0xB3000000)),
          ),
        ),
        SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(compact ? 8 : 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: ColoredBox(
                    color: Palette.panel,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(compact),
                        Expanded(child: _body(compact)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _body(bool compact) {
    final cues = _cues;
    if (cues == null) return _message(_error != null ? '$_error' : 'Reading the cue list…');
    if (cues.steps.isEmpty) return _message(_loading ? 'Reading the cue list…' : 'This playback has no cues.');
    return ListenableBuilder(listenable: widget.session, builder: (context, _) => _list(cues, compact));
  }

  /// The header's second line: the refresh state over a cached list, or
  /// the window's title once current.
  String get _subtitle {
    final title = _cues?.title.trim() ?? '';
    if (_cues != null && _error != null) return 'Refresh failed, showing the last list: $_error';
    if (_cues != null && _loading) return 'Refreshing… ${title.isEmpty ? '' : '($title)'}'.trim();
    if (title.isNotEmpty) return title;
    return 'Selects the playback on the console';
  }

  Widget _header(bool compact) {
    final session = widget.session;
    final pb = widget.playback;
    final name = session.playbackName[pb];
    final keyHeight = compact ? 34.0 : 38.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: Palette.raised,
        border: Border(
          left: BorderSide(color: Palette.strip(pb), width: 4),
          bottom: const BorderSide(color: Palette.slot, width: 2),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name == null ? 'PB ${pb + 1}' : 'PB ${pb + 1}  $name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.label.copyWith(fontSize: 14),
                ),
                Text(
                  _subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.small.copyWith(color: _error != null && _cues != null ? Palette.flash : null),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: compact ? 72 : 84,
            child: ConsoleButton(label: 'Reload', height: keyHeight, onDown: _reload),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: compact ? 64 : 76,
            child: ConsoleButton(label: 'Close', height: keyHeight, onDown: widget.onClose),
          ),
        ],
      ),
    );
  }

  Widget _message(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyles.body.copyWith(color: Palette.textDim),
      ),
    ),
  );

  Widget _list(CueList cues, bool compact) {
    final session = widget.session;
    final pb = widget.playback;
    // The running cue is lit, as on the strip; its number comes from CREP
    // feedback or the Playbacks window.
    final running = session.playbackCue[pb];
    final active = !session.hasPlaybackFeedback || session.playbackActive[pb];
    final rowHeight = compact ? 44.0 : 48.0;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: cues.steps.length,
      itemExtent: rowHeight + 4,
      itemBuilder: (context, i) {
        final step = cues.steps[i];
        final lit = active && step.cue == running;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: _CueRow(step: step, lit: lit, height: rowHeight, onTap: () => _jump(step.cue)),
        );
      },
    );
  }
}

class _CueRow extends StatefulWidget {
  const _CueRow({required this.step, required this.lit, required this.height, required this.onTap});

  final CueStep step;
  final bool lit;
  final double height;
  final VoidCallback onTap;

  @override
  State<_CueRow> createState() => _CueRowState();
}

class _CueRowState extends State<_CueRow> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final lit = widget.lit;
    final base = _pressed ? Palette.raisedHigh : Palette.raised;
    final text = widget.step.text;
    return Semantics(
      button: true,
      selected: lit,
      label: widget.step.toString(),
      child: GestureDetector(
        onTapDown: (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: widget.onTap,
        child: Container(
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: lit ? Color.alphaBlend(Palette.live.withValues(alpha: 0.24), base) : base,
            border: Border(
              left: BorderSide(color: lit ? Palette.live : Palette.edge, width: lit ? 4 : 1),
              bottom: const BorderSide(color: Palette.slot, width: 2),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  'Q${widget.step.cue}',
                  maxLines: 1,
                  style: TextStyles.value.copyWith(color: lit ? Palette.live : Palette.text),
                ),
              ),
              Expanded(
                child: Text(
                  text.isEmpty ? 'No text' : text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.body.copyWith(
                    fontSize: 14,
                    color: text.isEmpty ? Palette.textDim : (lit ? Palette.live : Palette.text),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
