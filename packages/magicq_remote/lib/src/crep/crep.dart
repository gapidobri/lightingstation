import 'dart:convert';
import 'dart:typed_data';

/// Default UDP port of the ChamSys Remote Ethernet Protocol.
const int defaultCrepPort = 6553;

/// Encodes a CREP datagram.
///
/// ```
/// 0x00 char[4] "CREP"   0x04 u16 version (0)
/// 0x06 u8  seq forward  0x07 u8  seq backward
/// 0x08 u16 length       0x0a ASCII command(s)
/// ```
Uint8List encodeCrep(String commands, {int sequence = 0}) {
  final body = ascii.encode(commands);
  final out = Uint8List(10 + body.length);
  out.setRange(0, 4, const [0x43, 0x52, 0x45, 0x50]);
  out[6] = sequence & 0xff;
  ByteData.sublistView(out).setUint16(8, body.length, Endian.little);
  out.setRange(10, out.length, body);
  return out;
}

/// CREP playback commands. MagicQ parses `<args separated by ,><letter>`;
/// playbacks are 1-based.
abstract final class CrepCommand {
  /// Encodes a level so MagicQ lands on an exact internal step (0..256).
  ///
  /// MagicQ (`FUN_1004888d0`) maps whole numbers as `pct * 256 / 100`
  /// rounded, which reaches only 101 of its 257 steps, and decimals as
  /// `pct * 256 / 100` truncated. So send a decimal biased a quarter step
  /// up, which truncates to exactly the wanted step.
  static String _pct(double percent) {
    final step = (percent.clamp(0.0, 100.0) * 256 / 100).round();
    if (step == 0) return '0';
    if (step == 256) return '100';
    return ((step + 0.25) * 100 / 256).toStringAsFixed(4);
  }

  /// Sets the fader level of [playback], [percent] in 0..100, at MagicQ's
  /// full 0..256 resolution.
  static String level(int playback, double percent) => '$playback,${_pct(percent)}L';

  static String activate(int playback) => '${playback}A';
  static String release(int playback) => '${playback}R';

  /// Flash (test) on: full level while held.
  static String test(int playback) => '${playback}T';

  /// Flash (test) off.
  static String untest(int playback) => '${playback}U';

  static String go(int playback) => '${playback}G';
  static String stop(int playback) => '${playback}S';
  static String back(int playback) => '${playback}B';

  /// Jumps [playback] to the step whose cue ID is [cue] ("5" or "5.5"),
  /// with the cue's own times, activating the playback if needed.
  ///
  /// MagicQ (`FUN_1004888d0`, `J`) matches `whole + hundredths / 100`
  /// against each step's cue ID and runs `FUN_10051ad40(pb, step, 0, 0)`,
  /// the timed jump; the same format it sends as feedback.
  static String jump(int playback, String cue) {
    final parts = cue.trim().split('.');
    final whole = int.tryParse(parts[0]) ?? 0;
    final decimals = parts.length > 1 ? '${parts[1]}00'.substring(0, 2) : '00';
    return '$playback,$whole,${int.tryParse(decimals) ?? 0}J';
  }

  /// Selects playback page [page] (1-based).
  static String page(int page) => '${page}P';

  /// Asks for the level and active state of playbacks [first]..[last]
  /// (1-based). In a tx mode MagicQ broadcasts `78,pb,level,active,...H`
  /// back on the CREP port (`FUN_100486300`, case 78), with the level at
  /// 0..256; see [interpretCrep].
  static String queryPlaybacks(int first, int last) => '78,$first,${last}H';
}

/// One parsed CREP command: numeric arguments followed by a letter.
class CrepMessage {
  const CrepMessage(this.command, this.args);

  /// Upper-case command letter, e.g. `L`.
  final String command;
  final List<double> args;

  int intArg(int i) => i < args.length ? args[i].round() : 0;

  @override
  String toString() => '${args.map((a) => a == a.roundToDouble() ? a.round() : a).join(',')}$command';
}

/// Parses a CREP datagram into its commands. Returns an empty list if it
/// is not CREP. MagicQ writes the magic as `PERC`; both byte orders are
/// accepted, as MagicQ itself does.
List<CrepMessage> decodeCrep(List<int> datagram) {
  if (datagram.length < 10) return const [];
  final magic = String.fromCharCodes(datagram.sublist(0, 4));
  if (magic != 'CREP' && magic != 'PERC') return const [];
  final length = datagram[8] | datagram[9] << 8;
  final end = (10 + length).clamp(10, datagram.length);
  return parseCrepCommands(String.fromCharCodes(datagram.sublist(10, end)));
}

/// Parses `1,50L2G`-style command text, following MagicQ's own parser:
/// digits, `.` and `-` build a number, `,` ends an argument, and a letter
/// ends the command. Anything else is ignored.
List<CrepMessage> parseCrepCommands(String text) {
  final out = <CrepMessage>[];
  final args = <double>[];
  final number = StringBuffer();

  void pushNumber() {
    args.add(double.tryParse(number.toString()) ?? 0);
    number.clear();
  }

  for (final c in text.codeUnits) {
    final isLetter = (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7a;
    if (isLetter) {
      pushNumber();
      out.add(CrepMessage(String.fromCharCode(c & ~0x20), List.unmodifiable(args)));
      args.clear();
    } else if (c == 0x2c) {
      pushNumber();
    } else if ((c >= 0x30 && c <= 0x39) || c == 0x2e || c == 0x2d) {
      number.writeCharCode(c);
    }
  }
  return out;
}

/// Playback state as reported by MagicQ in "ChamSys Rem (tx)" modes.
class PlaybackState {
  const PlaybackState({required this.playback, this.level, this.active, this.cue});

  /// 1-based.
  final int playback;

  /// 0..100, when reported.
  final double? level;
  final bool? active;

  /// Current cue ID, e.g. "1" or "2.5".
  final String? cue;
}

/// Turns MagicQ's transmitted CREP commands into playback updates.
///
/// MagicQ sends `pb,levelL` on level changes, `pb,levelLpbA` on activate,
/// `pbR` on release, `pb,cue,decimalJ` when a cue starts and `pageP` on
/// playback page changes (see `FUN_10048a660`..`FUN_10048b1a8`), and
/// `78,pb,level,active,...H` in reply to [CrepCommand.queryPlaybacks].
///
/// The reply's level is the playback's intensity table (`DAT_102084120`,
/// written by `FUN_10051a000`): the fader (or a held flash, at full)
/// scaled by the grand and sub masters, or those masters alone for a
/// stack whose fader doesn't control intensity. From the binary only.
({List<PlaybackState> playbacks, int? page}) interpretCrep(List<CrepMessage> messages) {
  final playbacks = <PlaybackState>[];
  int? page;
  for (final m in messages) {
    switch (m.command) {
      case 'L' when m.args.length >= 2:
        playbacks.add(PlaybackState(playback: m.intArg(0), level: m.args[1]));
      case 'A':
        playbacks.add(PlaybackState(playback: m.intArg(0), active: true));
      case 'R':
        playbacks.add(PlaybackState(playback: m.intArg(0), active: false));
      case 'J' when m.args.length >= 3:
        final whole = m.intArg(1);
        final hundredths = m.intArg(2);
        final cue = hundredths == 0
            ? '$whole'
            : '$whole.${hundredths.toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '')}';
        playbacks.add(PlaybackState(playback: m.intArg(0), cue: cue));
      case 'P':
        page = m.intArg(0);
      case 'H' when m.intArg(0) == 78:
        for (var i = 1; i + 2 < m.args.length; i += 3) {
          playbacks.add(
            PlaybackState(
              playback: m.intArg(i),
              level: (m.args[i + 1] * 100 / 256).clamp(0, 100),
              active: m.args[i + 2] != 0,
            ),
          );
        }
    }
  }
  return (playbacks: playbacks, page: page);
}
