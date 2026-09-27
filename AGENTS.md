# AGENTS.md

Guidance for coding agents working on Lighting Station.

## What this is

A Flutter app (`me.gapi.lightingstation`) for live control of ChamSys MagicQ
from a phone, in the spirit of Mixing Station for audio desks: playback
faders and the Execute grid, built for running a show, not programming it.
Phones are the primary target (portrait and landscape); tablets come later.

The protocol work comes from reverse-engineering MagicQ 1.9.8.3 (macOS) in
Ghidra, through the ghidra-mcp tools. Full protocol notes, with function
addresses, are in `packages/magicq_remote/README.md`. Read them before
changing anything in the package.

## Layout

```
lib/                          Flutter app (widgets only, no Material)
  main.dart                   WidgetsApp root; connect screen or console screen
  session.dart                ConsoleSession: LiveSession (real console) and DemoSession (offline)
  theme.dart                  Palette and TextStyles tokens
  wifi_lock.dart              Android Wi-Fi low-latency lock (method channel)
  screens/                    connect_screen.dart, console_screen.dart
  widgets/                    fader, console_button, playback_strip, execute_grid, text_input
packages/magicq_remote/       Pure Dart protocol package (no Flutter)
  lib/src/chwp/               CHWP: cipher, packet, messages, execute page, transport
  lib/src/crep/crep.dart      CREP: encoding, parsing, playback feedback
  lib/src/magicq_client.dart  MagicQClient: one live session with a console
  lib/src/discovery.dart      Console discovery by broadcast
android/app/src/main/kotlin/.../MainActivity.kt   Wi-Fi lock channel
```

## Commands

```sh
flutter analyze && flutter test                       # app
(cd packages/magicq_remote && dart analyze && dart test)  # package
flutter run --dart-define=DEMO=true                   # offline demo, no console needed
dart run packages/magicq_remote/example/magicq_remote_example.dart [ip]  # discover / dump Execute page
```

Formatting uses `dart format --line-length 120`. Keep both analyzers clean
and all tests passing.

## Protocols (summary)

The app speaks two MagicQ protocols, each for what it does well.

**CHWP**, the MagicQ Remote app protocol (UDP 4920 both ways). Used for the
Execute grid, console status and discovery.
- XOR-scrambled with a rolling key. The first plaintext byte is always `C`.
- 0x16-byte header (`CHWP`, version, sequence, type at 0x12, length at 0x14).
  The client announces version 2.25.
- MagicQ always replies to port 4920 on the sender's IP. So the client must
  bind 4920, and it can't run on the same machine as MagicQ (the iOS
  simulator included).
- Only one socket may own 4920 per device. `ChwpTransport.acquire()` and
  `release()` share a single reference-counted socket between discovery and
  the client. Never call `ChwpTransport.bind()` for 4920 anywhere else: iOS
  and macOS fail a second bind with errno 48.
- The client polls the Execute page every 250 ms. That doubles as a
  keepalive and keeps status (0x8002) updates coming.

**CREP**, the ChamSys Remote Ethernet Protocol (UDP 6553). Used for playback
faders, buttons and feedback, because CHWP has no playback messages.
- ASCII commands such as `1,50L`, `1G`, `1T`/`1U`, `1A`/`1R`, `2P`, under a
  10-byte `CREP` header.
- **Levels:** MagicQ maps whole-number percents to only 101 of its 257
  fader steps. `CrepCommand.level` sends a decimal biased by a quarter step,
  so every step is reachable. A test checks all 257. Keep that.
- **Rate:** MagicQ applies remote levels once per main-loop tick (~30 Hz)
  and keeps only the latest value. While a fader moves, the client streams
  its level every 33 ms and holds for 300 ms after the last movement. Don't
  go back to sending on each touch event.
- **Feedback:** in "ChamSys Rem (tx + rx)" mode, MagicQ broadcasts
  `L`/`A`/`R`/`J`/`P` on port 6553, with the magic written as `PERC`. The
  client binds 6553 (falling back to send-only if it's taken). The app
  ignores level echoes for a playback for 400 ms after a local move.

## Known limitations and decisions

- **Flash, Go and Pause don't match the console's buttons.** CREP (and
  OSC/MIDI) call playback functions directly and skip MagicQ's button
  mapping. So speed-master tap tempo, "Go uses Exec Grid" and similar
  settings aren't applied. Only real console keycodes get that behaviour
  (Flash n = 0x100+n-1, Pause = 0x10a+, Go = 0x114+, Select = 0x127+).
- **Full remote control (multi-console protocol, TCP, `CHMQ` framing)** can
  send real keycodes. It requires a console licensed and unlocked for remote
  control; the user has that licence. The agreed plan: use it only for
  playback buttons, after a test client confirms native behaviour and that
  the console's selected window doesn't change. Remote key input names a
  target window, and MagicQ selects that window. Not started yet.
- **Don't work around MagicQ licensing or unlock checks.** Only use features
  the console legitimately has enabled.
- CHWP Execute presses don't change the console's focused window, but they
  do join console-wide pending modes (Copy, Set, ...).
- MagicQ in demo mode rejects CHWP changes (page requests still work).
- Choppy faders over Wi-Fi come from Wi-Fi power saving, not the protocol.
  Recommend a wired MagicQ computer. Android holds a low-latency Wi-Fi lock
  while connected; iOS has no equivalent.
- Execute page-navigation items only change the phone's own page.

## Console setup (for testing and user-facing text)

- Setup > View Settings > Network: "Enable remote app". Set "Ethernet
  remote protocol" to "ChamSys Rem (tx + rx)" and the port to 6553.
- Playback feedback on a standalone console probably needs the cue stack
  option "Send playback state to other consoles" (unconfirmed).
- If MagicQ has users configured, CHWP connect sends `password\0user`.

## UI conventions

- No Material or Cupertino. Use `WidgetsApp` and custom widgets only, in a
  dark, dense desk style. Tokens are in `theme.dart`. Colour carries meaning:
  amber for running/active, red for flash, a per-strip colour for each
  playback.
- Buttons fire on pointer down (`Listener`), not on tap release.
- Faders use relative drag, so they never jump to the finger.
- Borders with mixed colours can't use `borderRadius`; clip with
  `ClipRRect` instead.
- Compact (phone) layout applies when `shortestSide < 600`. The page stepper
  goes in the top bar only when the width is at least 700.
- Check UI changes visually. Build the macOS app with
  `--dart-define=DEMO=true`, resize the window (e.g. 390x844 or 844x390 for
  phones), and take screenshots. Synthetic clicks from AppleScript don't
  reach Flutter; use CGEvent-posted mouse events.

## Working with the user

- Phone first. Keep the compact layout working in both orientations.
- No git: the user declined `git init`, so don't create a repo or commit
  unless asked.
- When reverse-engineering, confirm behaviour in the MagicQ binary before
  building on it. Mark anything unconfirmed as such in docs and replies.
