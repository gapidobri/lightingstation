# AGENTS.md

Guidance for coding agents working on Lighting Station.

## What this is

A Flutter app (`me.gapi.lightingstation`) for live control of ChamSys MagicQ
from a phone, in the spirit of Mixing Station for audio desks: playback
faders and the Execute grid, built for running a show, not programming it.
Phones are the primary target, landscape only (locked in Flutter, iOS
Info.plist and the Android manifest); tablets come later.

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
  widgets/                    fader, console_button, hold_button, playback_strip, execute_grid, cue_picker, text_input
packages/magicq_remote/       Pure Dart protocol package (no Flutter)
  lib/src/chwp/               CHWP: cipher, packet, messages, execute page, windows, transport
  lib/src/crep/crep.dart      CREP: encoding, parsing, playback feedback
  lib/src/chmq/               CHMQ (multi-console): codec, MagicQRemoteControl (native buttons, screen sync), strip parsing
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
dart run packages/magicq_remote/example/magicq_remote_example.dart <ip> window 17  # dump a CHWP window (17 = Playbacks)
dart run packages/magicq_remote/example/remote_control_example.dart <ip> <flash|go|pause> <pb>  # native button test
dart run packages/magicq_remote/example/remote_control_example.dart <ip> sync 10  # print strips / selected window
dart run packages/magicq_remote/example/remote_control_example.dart <ip> cues 1 [5.5]  # select PB1, list cues, jump```

Formatting uses `dart format --line-length 120`. Keep both analyzers clean
and all tests passing.

## Protocols (summary)

The app speaks two MagicQ protocols, each for what it does well.

**CHWP**, the MagicQ Remote app protocol (UDP 4920 both ways). Used for the
Execute grid, console status, playback names and cues, and discovery.
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
- Playback names come from the CHMQ playback strips (see screen sync); the
  Playbacks window below is the fallback while that link is down. Current
  cue numbers come from the Playbacks window
  (window request 0x08, window 0x11), polled every 500 ms, and CREP. It is
  read-only and selects no window on the console. The window's item list
  depends on its layout on the console. Confirmed live in view 1: names
  and the active cue number come through (cell state 1 = active, 2 =
  idle), but no cue text. Its status view (view 4) has current and next
  cue text, but MagicQ PC without wings forces it off (confirmed live).
  Cue text comes from the CHMQ playback strips instead (see screen sync).

**CREP**, the ChamSys Remote Ethernet Protocol (UDP 6553). Used for playback
faders, buttons and feedback, because CHWP has no playback messages.
- ASCII commands such as `1,50L`, `1G`, `1T`/`1U`, `1A`/`1R`, `2P`,
  `1,5,50J` (jump to cue 5.5), under a
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
  Moves made at the console itself are broadcast too (confirmed live with
  Net Sessions "Disabled", after a MagicQ restart). See known limitations.
- **Resync:** feedback only reports changes, so on connect and whenever
  the console comes back online the session sends `78,1,10H` (asked twice,
  1 s apart). MagicQ replies `78,pb,level,active,...H` (level 0..256),
  confirmed live, for every playback whatever its stack options. The level is the playback's intensity: the
  fader scaled by the grand/sub master, full while flashed, and the
  masters alone for a stack whose fader doesn't control intensity.

## Known limitations and decisions

- **Over CREP, Flash, Go and Pause don't match the console's buttons.** CREP
  (and OSC/MIDI) call playback functions directly and skip MagicQ's button
  mapping, so speed-master tap tempo, "Go uses Exec Grid" and similar
  settings aren't applied.
- **Full remote control** (multi-console protocol, `CHMQ`) is always
  linked, with no toggles: it always carries the playback buttons (native,
  so MagicQ's own button handling applies) and always mirrors the
  console's screen (screen sync, below). Faders stay on CREP, and the
  Execute grid and status stay on CHWP. Don't send other input over it:
  faders would need synthesized mouse drags.
- **Screen sync** (the user allowed it) asks for a screen dump (type 0x06,
  flags 0x05, as MagicQ's own controller does) every 250 ms, about 25 KB
  each. The app uses the playback strips above the on-screen faders (type
  0x0e, widget 300 + pb - 1): each playback's current and next cue text
  (both shown on the strip) and, for a speed master stack, `SP<n>`, BPM,
  multiplier and Running/Halted. The status (type 0x0f) also reports the
  console's selected window; nothing uses it now. Confirmed live on
  MagicQ 1.9.7.3 (strips, BPM, selected window); the multiplier text is
  **from the binary only**. No other network path links a playback to its
  speed master on MagicQ PC without wings: the Playbacks window's status
  view is forced off there, and its speed-master view (5) has no
  playbacks and can't be selected remotely.
- **Cue picker: on demand only, no background scanning.** Tapping a
  strip's scribble area opens `CuePicker`. It presses that playback's
  Select key over CHMQ (needs the link, no CREP fallback), waits for the
  Cue Stack window's title to change (MagicQ switches it ~0.85 s after
  the press, measured live; a fixed 250 ms wait read the previous
  playback's stack), reads the Cue Stack window (0x0e, which follows the console's selected
  playback; CHWP has no way to name a stack) and lists "Cue id" and
  "Cue text". The session caches each list per (playback page,
  playback); reopening shows the cached list at once and still reads it
  again (so it still presses Select) every time. Opening it **changes
  the console's selected playback**;
  the user accepted that. Never scan playbacks in the background (an
  earlier version did, and it was removed). Tapping a cue sends CREP
  `pb,whole,hundredthsJ`: a timed jump with the cue's own times that
  activates the playback (`FUN_1004888d0` `J` → `FUN_10051ad40(pb, step,
  0, 0)`). Jump and window layout are **from the binary only**; whether
  the window's item count covers long stacks, and what its title shows,
  are unconfirmed. Test with `remote_control_example.dart <ip> cues <pb>
  [cue]`. Risk: a Select press joins a pending mode (Record, Copy, ...)
  like a local press would.
  - The console connects back: the app listens on TCP 4911 and sends a UDP
    request to the console's 4910. The app sends a hello every 50 ms.
  - Buttons are input subtype 4 (console button by board index), which
    selects no window. Never use subtype 0 (keyboard keys): MagicQ selects
    and opens the target window first.
  - Needs "Enable remote control" and a licence unlocked for remote control
    (the user has one). While the link is down, the buttons fall back to
    CREP. A release always takes the same path as its press.
  - The link is confirmed against MagicQ 1.9.8.3. Native button behaviour
    and a steady selected window are **not yet confirmed on a licensed
    console**. Test with the example before relying on it. If the window
    does move, the per-monitor Setup option "Select fixed window for this
    monitor" pins it (from static analysis only).
- **Don't work around MagicQ licensing or unlock checks.** Only use features
  the console legitimately has enabled.
- CHWP Execute flash items take the down bit inverted (clear = on, set =
  release; confirmed live). `MagicQClient.setExecuteButton` handles it;
  don't send the plain encoding for them. Active group items that share
  an item group arrive as state 1 without a colour; the page assembler
  restores it.
- CHWP Execute presses don't change the console's focused window, but they
  do join console-wide pending modes (Copy, Set, ...).
- The app assumes a fully licensed MagicQ and doesn't support MagicQ's
  demo mode (it rejects CHWP changes and remote-control input).
- Choppy faders over Wi-Fi come from Wi-Fi power saving, not the protocol.
  Recommend a wired MagicQ computer. Android holds a low-latency Wi-Fi lock
  while connected; iOS has no equivalent.
- Execute page-navigation items only change the phone's own page.
- **CREP feedback of console-side moves works with Net Sessions
  "Disabled".** Confirmed live after restarting MagicQ: with "ChamSys Rem
  (tx + rx)", fader moves made at the console reach the app. Before that
  restart, the same settings only echoed the app's own moves, so if
  feedback stops, restart MagicQ before debugging. From the binary, with
  Net Sessions off `FUN_10048a8e0` only sends a playback whose cue stack has
  "Send playback state to other consoles" set (`+0x94` bit 0). Confirmed
  live: a stack set to No reports nothing. Link flag 0x4000 on the CHMQ
  link (which feeds the global `DAT_10238d7d4` gate in the binary) was
  tried and **does not** make other stacks report; don't retry it.
- **Don't use Net Sessions.** A sync mode makes every playback broadcast
  (`DAT_10228b400 = 7`), but changing Net session mode resets Ethernet
  remote protocol to off (`FUN_1001737e0` clears `_DAT_10228b05c`), so the
  console ignores the app's commands. It is also multi-console sync with a
  show-sync risk.

## Console setup (for testing and user-facing text)

- Setup > View Settings > Network: "Enable remote app". Set "Ethernet
  remote protocol" to "ChamSys Rem (tx + rx)" and the port to 6553.
- Keep Net Session mode "Disabled". Changing it switches Ethernet remote
  protocol off.
- Console-side moves are reported per cue stack: "Send playback state to
  other consoles" = Yes (confirmed live; see known limitations).
- If MagicQ has users configured, CHWP connect sends `password\0user`.

## UI conventions

- No Material or Cupertino. Use `WidgetsApp` and custom widgets only, in a
  dark, dense desk style. Tokens are in `theme.dart`. Colour carries meaning:
  amber for running/active, red for flash, a per-strip colour for each
  playback.
- Buttons fire on pointer down (`Listener`), not on tap release.
- Go sits above Pause on every layout. They show painted play and pause
  icons (`TransportIcon`; the app has no icon font). Current cue text starting with
  `E<pb> ` (E1 for playback 1) labels Go with the rest of the text, and
  next cue text starting with `E<pb + 10> ` (E11 for playback 1) labels
  Pause; the labelling line is hidden on the strip.
- The screen stays awake while the app is open (`FLAG_KEEP_SCREEN_ON` in
  MainActivity, `isIdleTimerDisabled` in AppDelegate).
- Faders use relative drag, so they never jump to the finger.
- Exit (Disconnect) must be held for 800 ms (`HoldButton`, with a ring
  that fills while held), so a stray touch can't drop the link mid-show.
- The top bar has view buttons (Playbacks, Execute, Split) and toggles
  for the strips' Go/Pause and Flash keys; hiding keys gives the faders
  their room. Split view puts scrolling playbacks on the left and the
  Execute grid on the right; its two page steppers (playbacks first)
  share the top bar.
- Execute cells keep their size from the console (`ExecutePage.layout`).
  A cell shows its type tag (PB, CS, G, ...) only when the whole name
  still fits above it. Flash items light red while held.
- Borders with mixed colours can't use `borderRadius`; clip with
  `ClipRRect` instead.
- Compact (phone) layout applies when `shortestSide < 600`. Page steppers
  always sit in the top bar, never on their own row; a stepper whose label
  doesn't fit shows just the page number.
- Space is tight on phones: keep new UI tidy and compact (short labels, no
  extra rows) and check it at 667x375 as well as 844x390.
- Check UI changes visually. Build the macOS app with
  `--dart-define=DEMO=true`, resize the window to a landscape phone (e.g.
  844x390, or 667x375 for a small one), and take screenshots. Synthetic clicks from AppleScript don't
  reach Flutter; use CGEvent-posted mouse events.

## Working with the user

- Phone first, landscape only. Keep the compact layout working on small
  and large phones.
- No git: the user declined `git init`, so don't create a repo or commit
  unless asked.
- When reverse-engineering, confirm behaviour in the MagicQ binary before
  building on it. Mark anything unconfirmed as such in docs and replies.
