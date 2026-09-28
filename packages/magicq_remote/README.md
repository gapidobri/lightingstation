# magicq_remote

Dart client for ChamSys MagicQ's network remote protocols:

- **CHWP**, the protocol of the official MagicQ Remote app. Used for
  Execute pages, console status and discovery.
- **CREP** (ChamSys Remote Ethernet Protocol). Used for playback faders
  and buttons, because CHWP has no playback messages.

The protocol details below were recovered from MagicQ 1.9.8.3 (macOS) in
Ghidra. Function addresses are included so they can be re-checked against
newer builds.

```dart
final client = await MagicQClient.connect('192.168.1.10');
client.executePages.listen((page) => print(page.name));
client.setExecuteButton(3, pressed: true);
client.setPlaybackLevel(1, 75); // percent, over CREP
```

`dart run example/magicq_remote_example.dart [ip]` discovers consoles, or
dumps a console's current Execute page. `... <ip> window 17` dumps a window's cells
(17 = Playbacks) and what the client reads from them.

## Console setup

- CHWP: Setup, "Enable remote app". If MagicQ has users configured, pass
  `user`/`password`.
- CREP: Setup, "Ethernet remote protocol" = `ChamSys Rem (tx + rx)`, port
  6553 ("Ethernet remote port"). `(rx)` alone works too, without feedback.
- Playback changes made at the console (mouse/fader) are broadcast over CREP
  with Net Session mode "Disabled" (confirmed live after restarting MagicQ,
  MagicQ 1.9.8.3). They are reported per cue stack, via "Send playback
  state to other consoles". Keep Net Sessions disabled: changing it
  switches Ethernet remote protocol off. See [Feedback](#feedback-tx-modes)
  below.
- MagicQ in demo mode rejects every CHWP change except page requests
  ("Remote changes not supported in MagicQ Demo mode").

## CHWP

UDP port **4920** in both directions. MagicQ replies to port 4920 on the
sender's IP, not to the source port, so the client must bind 4920. As a
result it cannot run on the same host as MagicQ (the iOS simulator
included).

### Scrambling

Every datagram is XOR-scrambled with a rolling key (sender `FUN_100545f50`,
receiver `FUN_10053ff10`):

```
key = random byte
for i in 0..len-1:
    out[i] = plain[i] ^ key
    key    = rotl8((plain[i] + key + i + 0x93) & 0xff, 2)
```

The receiver recovers the seed from the first byte, which is always `'C'`:
`key = data[0] ^ 0x43`.

### Header (0x16 bytes, little endian)

| Offset | Type     | Field                                           |
|--------|----------|-------------------------------------------------|
| 0x00   | char[4]  | `CHWP`                                          |
| 0x04   | u8, u8   | protocol version major, minor (MagicQ sends 2.25) |
| 0x06   | u16      | sequence                                        |
| 0x08   | u8[10]   | zero                                            |
| 0x12   | u16      | message type (replies: `type \| 0x8000`)        |
| 0x14   | u16      | payload length                                  |

MagicQ stores each client's version and gates features on it (for example,
v2.12+ gets the extended Execute item format). This client sends 2.25.

### Messages (payload offsets)

| Type | Direction | Payload | Handler |
|------|-----------|---------|---------|
| 0x01 connect | → | `u32 0`, then optional `password\0user\0` | `FUN_10053f860` |
| 0x8001 | ← | `u32 status` (0 ok, 1/2 logged in, 3 unknown user, 4 wrong password), `char[16]` name | |
| 0x02 key | → | `u16 key index`, `u16 flags` (bit 0 = down) | `FUN_100540c00` |
| 0x03 encoder | → | `u16 encoder`, `i16 delta` | `FUN_100540d60` |
| 0x04 execute button | → | `u16 item index`, `u16 flags` (bit 0 = down) | `FUN_100541220` |
| 0x05 colour picker | → | RGB bytes | `FUN_100541810` |
| 0x06 execute page | → | `u16 page`, `u16 mode` (1 = colours), `u16 select` (1 = switch to `page`, 0 = current page) | `FUN_100541ad0` |
| 0x8003 | ← | Execute page, see below | |
| 0x08 window | → | `u16 0`, `u16 window id` (≤ 0x33), `u16 first item`, `u16 item count`. Read-only, allowed in demo mode | `FUN_100543870` |
| 0x8006 / 0x8008 / 0x8007 | ← | window header, column headers (tables only), items; see [Windows](#windows) | |
| 0x09 window items | → | items only (same layout as 0x08) | `FUN_100543d60` |
| 0x0c window select | → | `u16 flags` (bit 0: select the window, running its select command 0x12e, which opens it; else select `item`, or for the Playbacks window with item 0..4 set its view), `u16 window`, `u16 item`. Changes the console's screen | `FUN_10053ff10` |
| 0x0b / 0x0c window item | → | press/select an item in a MagicQ window | |
| 0x0e execute fader | → | `u16 item index`, `u16 0`, `u16 level 0..255` | `FUN_1005414b0` |
| 0x0f execute encoder | → | `u16 item index`, `u16 flags`, `i16 delta` | `FUN_100541610` |
| 0x14 info | → | empty; answered even for unregistered clients | `FUN_100544d90` |
| 0x800d | ← | see `ConsoleInfo.parse` | |
| 0x8002 status | ← | `u32 flags`, `char[12]`, `char[99]` "message\ncommand line" | `FUN_100542530` |

Clients stay registered in a 100-slot table; any packet from a registered
client refreshes it. Status (0x8002) is only pushed to clients heard from
recently, so the client polls the Execute page every 250 ms.

Key indices for 0x02 map through the table at `0x101e3da70` (0..9 are the
digit keys).

### Execute page reply (0x8003)

MagicQ splits large pages across several datagrams. Each one repeats the
header and says which item it starts from. Short datagrams are padded to
0x33a bytes with stale buffer contents, so parse by item count, not by
payload length.

```
0x00 u32 page flags   0x04 u16 page   0x06 u16 columns   0x08 u16 rows
0x0a char[16] name    0x1a u16 first item index           0x1c items...

item (FUN_100365930 fills it):
  u16 flags    bit0 exists, bit3 flash, bit4 fader, bit10 has icon
  u16 borders  bits0..3 region edge top/bottom/left/right,
               bit7 fader spans the cell below, bit9 cell is that lower half
  u32 extra    bit7 active (colour mode); bits 24..27 height - 1,
               bits 28..31 width - 1 (item size in cells, see below)
  u32 state    1 active / 2 inactive; colour mode: 0x80000000 | RGB
  u32 icon id  (0xfd000000 = bitmap named by tag)
  u16 level    0..255
  cstring text, cstring name, cstring tag ("PB", "CS", "FL", "LVL", ...)
```

Regions: an item with a non-zero region (item group) id gets a border
bit for each side whose neighbouring cell is empty, off the page, or in
another region (`FUN_100368630`; zone items, type 0x18, get the same
bits against neighbouring zones). Only the edge bits go over the wire,
not the id. Neighbours are the raw grid cells, so a sized item's edges
follow its top-left cell. From the binary only, not confirmed live.

Item size: MagicQ keeps each item's size in the top byte of its own
flags (bits 24..27 height - 1, bits 28..31 width - 1; the Execute
window's height and width soft buttons step them, `FUN_10036b920`) and
copies that byte into `extra`'s top byte (`FUN_100368630`). A fader only
gets the automatic "spans the cell below" border bit when that byte is
zero. From the binary only: how MagicQ reports the cells a sized item
covers is not confirmed live, so `ExecutePage.layout` drops any item
there. Flash items (`FL`, flags bit 3) are on only while held, and
MagicQ reads the 0x04 down bit the other way round for them: bit clear
turns the flash on, bit set releases it (confirmed live; both are
idempotent). With the plain encoding a flash latched on release and
went off on the next press. `MagicQClient.setExecuteButton` inverts the
bit for flash items and sends a release the same way as its press.

Group items that share an item group with others come with flags bit 15
clear. Inactive, they report their dimmed colour (MagicQ dims inactive
colours to 0.51); active, plain state 1 with no colour and `extra` bit 7
clear (`FUN_100365930`, confirmed live). `ExecutePageAssembler` gives
an active one back its full colour and bit 7, from the dimmed colour
seen before, or MagicQ's default group colour `0xbb0030`.

### Windows

The window id indexes MagicQ's window table (names at `0x101e3dfa0`,
20 bytes each): 0x0d Stack Store, 0x0e Cue Stack, 0x10 Cue Store,
0x11 Playbacks, 0x1b Execute. Every window except a few visualiser and
media ones is created at startup (`FUN_1005528b0`), so a request doesn't
need the window open on the console, and it doesn't select it. Which
items a window has depends on its layout on the console (the item count
is window table `+0x70`).

0x8006 header: `u16 window`, `u16 kind` (1 = table), `u16 view`
(`+0x892c`), `u16`, `u32 items`, `u32 columns`, `u32`, `u16 title length`,
title.

0x8008 column headers (only for table windows, kind 1): `u16 window`,
`u16 count`, then the names from window table `+0x3266` as cstrings.

0x8007 items (split at ~0x538 bytes): `u16 window | page << 8`, `u16 count`,
then per item: `u16 index`, `u16 item length`, `u16 value`, `u16 flags`
(bit 2 = cursor), `u32 colour`, `u32 state`, then three cstrings. Each
window class fills them through its `Boxs` vtable `+0x1a8` method. For
the Playbacks window (`PlaybackBoxs`, `FUN_10041d750`) in its default view:

- text: `PB<n>` (1-based; " T" or " DEF" may follow), `W<wing>-<n>` for
  wing playbacks, and `Main` / `Wing <n>` header cells
- name: the cue stack name (`%.15s`), or `CS<n>` when unnamed
- value: the current cue as `%2.2f` while the playback is active,
  otherwise the stack's cue count as `%i`
- state: 2 = stack, 1 = active, 3 = level up, 7 = (unknown flag)

In the status view (`+0x892c` = 4; 0x8006 reports the view) each column
is a playback (`+0x74` = 12 columns, `+0x78` rows), filled from
`FUN_100524340`: a label cell (text `PB<n>` plus a tag, name = stack name,
value = progress) and the cell one row below it with text = current cue
text (step `+4`, `%2.2f` when empty, or `%2.2f %.12s` with the cue-number
display option) and name = next cue. When there are more than 11 rows the
top rows are an upper bank (playbacks +15), with a fader (flags bit 15) or
Flash (`FL`, flags bit 7) cell under the label instead. MagicQ forces view
4 back to 0 on MagicQ PC without wing hardware (`FUN_10041d010`) unless
`DAT_10228b398` is 3 (a hardware/licence type, not a setting). Views 2
and 3 put the page (`P%i`) or a page count in the value. View 5 ("PLAYBACKS
(Speed Masters)") is a table of speed masters instead of playbacks: 100
rows (SP1..SP100, records of 0x30 bytes at `0x10227cf40`), 14 columns:
`SP%i`, name (`+0x20`), Enabled, BPM (`60 / float +4`), Running/Halted
(flags bit 2), multiplier (`+0x18`), BPM (`+8`), ..., source (Tap, Audio
BPM, DJ BPM). It has no link to playbacks; a stack names its speed master
at `+0x9e`. The client reads the standard and status views only
(`PlaybackWindowReader`).

CHWP 0x0c with flags 0, window 0x11 and item 0..4 sets the Playbacks
window's view (`FUN_10041c210`); confirmed live. View 5 can't be reached
that way. Confirmed live in view 1 (12 columns,
204 items; the main playbacks first, then `W<n>-<m>` wing cells): stack
names, and the cue number as `1.00` for active playbacks (state 1) or the
cue count as `1` for idle ones (state 2), with no cue text. The status view
is from the binary only. The cells above MagicQ PC's on-screen faders
show current and next cue text, but they're local widgets: `FUN_100526b90`
fills them (`FUN_10047dd90`, `FUN_10047de90`, `FUN_10047e980` only update
Qt widgets) and sends the same text to wing LCDs over USB
(`FUN_100332410` → `create_arm_usb_link`). No network protocol carries it,
apart from the Playbacks window's status view.

## CREP

UDP port 6553 (configurable). The header is `CREP`, `u16 version (0)`,
`u8 seq fwd`, `u8 seq back`, `u16 length`, followed by ASCII commands of the
form `args,separated,by,commasLETTER` (parser `FUN_100489220`, commands
`FUN_1004888d0`). Playbacks are 1-based.

| Command | Meaning |
|---------|---------|
| `n,lL`  | playback n level l (0..100). Whole numbers map to only 101 of MagicQ's 257 steps (`FUN_10028dc50`); decimals are truncated from `l*256/100`, so the client sends `(step+0.25)*100/256` to hit every step |
| `nA` / `nR` | activate / release |
| `nT` / `nU` | flash (test) on / off |
| `nG` / `nS` / `nB` | go / stop / back |
| `n,c,hJ` | jump to the step whose cue ID is `c + h/100` (`2,5,50J` = cue 5.5), with the cue's times; activates the playback. From the binary only: `J` compares each step's float cue ID (step `+0`, 0x70 bytes each) within a tolerance (`FUN_100277970`) and calls `FUN_10051ad40(pb, step, 0, 0)`, the timed jump (`B`/`F` pass 1, a snap) |
| `nP`    | playback page |
| `78,first,lastH` | query playbacks (1-based): in a tx mode MagicQ broadcasts `78,pb,level,active,...H` (level 0..256, split past 1000 characters; `FUN_100486300`, case 78). Confirmed live on 1.9.8.3, for every playback regardless of the stack's send option |

The level in the `78` reply is `DAT_102084120`, which `FUN_10051a000`
recomputes on each level change: max(fader, flash level) scaled by two
master levels (`DAT_10208f652`, `DAT_10208f654`; grand and sub master,
0x100 = full), or just the masters for a stack whose fader doesn't control
intensity (`+0x90` bit 4 clear). The fader table itself
(`PTR_DAT_101ccb7f0`, what `L` sets) isn't reachable over CREP. The app
sends this query when it connects and when the console comes back online,
so faders start where the console's are.

### Feedback (tx modes)

The protocol option is a bit field (table at `0x101e0e060`): 1 = rx,
2 = tx, 0x8000 = no header, 0x4000 = echo. In a tx mode MagicQ broadcasts
(to every interface's broadcast address, `FUN_1001506a0`) on the CREP port,
with the same header but the magic written as a little-endian u32, so the
bytes read `PERC`. Commands are batched into one datagram per tick
(`FUN_1001508a0`). What it sends:

| Command | When | Sender |
|---------|------|--------|
| `pb,levelL` | level changed (0..100) | `FUN_10048a8e0` |
| `pb,levelLpbA` | playback activated | `FUN_10048aa40` |
| `pbR` / `pb,nR` | released | `FUN_10048aba0` |
| `pb,cue,hundredthsJ` | cue started (`2,5,50J` = PB2 cue 5.5) | `FUN_10048a660` |
| `pageP` | playback page changed | `FUN_10048ade0` |
| `6\|7,pb,nV`, `8\|9,nV` | other state, not decoded | `FUN_10048b0e0`, `FUN_10048af50` |

**Confirmed live (MagicQ 1.9.8.3):**

- Net Session mode "Disabled", `ChamSys Rem (tx + rx)`, after restarting
  MagicQ: moves made at the console are broadcast. Before that restart the
  same settings only echoed the app's *own* CREP moves, in every `tx`
  option. Restart MagicQ before debugging missing feedback.
- Net Session mode "Sync Manual Takeover": moves made at the console are
  broadcast, but the console ignores the app's commands. Changing Net
  session mode runs `FUN_1001737e0`, which clears `_DAT_10228b05c` (the
  Ethernet remote protocol option), so CREP rx is off.

`FUN_10048a8e0` (the sender for `pb,levelL`) sends when `DAT_10238d7d4` is
set, or `DAT_10228b400 & 1` ("Net Sessions, Playback sync") is set, or bit 0
of the cue stack's flags at `+0x94` is set. `FUN_1001737e0` sets
`DAT_10228b400 = 7` for net modes 1-3. The settings loader (`FUN_1001a82b0`)
forces it to 0 when net mode is 0. Every level setter (`FUN_10051a7d0`,
`FUN_10051b350`, `FUN_10051b430`, `FUN_10051b600`, ...) goes through
`FUN_100520f10`, then `FUN_100520de0`, into `FUN_10048a8e0`, so local moves
do reach the gate.

Net Sessions is multi-console sync (Master/Slave, show transfer). Alone on
the network the console promotes itself to Master. Another MagicQ in a
matching session may sync show data with it.

MagicQ's own help for the cue stack option says it sends that playback's
state when Ethernet Remote Protocol is "ChamSys TX" or "ChamSys TX and RX",
which matches the working setup. Still **not** confirmed:

- Whether cue-stack `+0x94` bit 0 is actually the bit the "Send playback
  state to other consoles" option writes. `+0x94` is a common offset reused
  by unrelated structs elsewhere in the binary, and static xrefs to that
  option's string (`0x101cf1ed2`) don't resolve to a traceable write site
  (likely a runtime menu-descriptor table `get_xrefs_to`/byte-pattern search
  couldn't follow). So the option may set a different bit, or a different
  field entirely.

**Tried and failed:** `DAT_10238d7d4` looks like a remote-control link
flag, not an interface setting, but setting it from the app does nothing
visible. A link announcing 0x4005 in every type 6 got no feedback for a
stack set to No: no CREP broadcast and no type 0x41 frame (capture,
MagicQ 1.9.8.3). The app doesn't send 0x4000. The static reading was: Its only writer, `FUN_100173cc0`, is called from
`FUN_1001623b0`, which checks the ten multi-console links (connected
`DAT_101f2b5f0 + 4n`, link flags `DAT_101f2baa0 + 2n`) and passes 1 when
any connected link has flag 0x4000. `FUN_100173cc0` sets the flag only
while "Enable remote control" (`DAT_10228b394`) is on and `DAT_10238dd44`
isn't 2. The type 6 handler (`FUN_10016e5d0`) stores the new flags and
runs `FUN_1001623b0` whenever 0x4000 changes; the UDP link request stores
flags without it. With the flag set, `FUN_100488360` would also send each
CREP feedback message to 0x4000 peers in its network table as a type 0x41
frame (`FUN_100163380`). Neither happened live; which gate stops it
(`DAT_10238dd44`, `DAT_10228b398`, the peer table) is unknown.

### OSC feedback (alternative, static analysis only)

MagicQ's OSC receiver (`FUN_100871940`) accepts `/feedback/pb`,
`/feedback/exec`, `/feedback/pb+exec`, `/feedback/all` and `/feedback/off`
(the mode is a path segment, no arguments). With `pb` subscribed,
`FUN_100876230` sends `/pb/N <float level/255>` and `/pb/N/flash <int>` for
PB 1-10 whenever a level changes, from the same level table
(`PTR_DAT_101ccb7f0`) that every level setter writes, plus a snapshot on
subscribe. The subscription is global, not per client. `FUN_100874900`
sends to "OSC tx IP" if set, otherwise to a stored list of IP:port pairs
(probably recent OSC senders), otherwise broadcast on the tx port. Needs
"OSC mode" with tx, and a non-zero tx port (defaults: rx 8000, tx 9000).
Also gated by `FUN_10005afc0(0x19)`, a licence feature check that can't be
evaluated in the patched local binary. OSC `/pb/N` input is truncated to a
whole percent, so keep CREP for sending levels.

## Full remote control (multi-console protocol)

MagicQ's "Remote control another MagicQ" uses the multi-console network
protocol (dispatcher `FUN_10016e8d0`, about 65 message types), not CHWP.
`MagicQRemoteControl` uses it only to press the playback buttons, so they
behave exactly like the console's own (CREP bypasses MagicQ's button
handling).

**Link.** The console opens the TCP connection. The client listens on TCP
4911 and sends a 28-byte UDP request to the console's port 4910
(`FUN_100170150` builds it, `FUN_100161e90` receives it): header, u16 link
flags at 0x0a, name at 0x0c. Type 0x16 requests are ignored. MagicQ then
connects to the sender's 4911 (`FUN_1001612b0`), using the request's flags
as the link flags. The console only handles requests while a network mode
such as "Enable remote control" is on. Its own listener on 4911 is open only
while it is itself a controller.

**Frames** (`FUN_10016f350`): `CHMQ`, u8 version (MagicQ writes 0x1b), u8
length bits 16..23 (versions > 6), u16 total length, u16 type, body at 0x0a.

| Type | Use |
|------|-----|
| 0x01 | Hello, 28 bytes. Header version = peer version. u16 at 0x0a bit 0 set means "don't reply". |
| 0x06 | Link flags (u16 at 0x0a). Without 0x10/0x400, the console starts streaming its windows (`FUN_100481b30`). |
| 0x10 | Input, 32 bytes (`FUN_100482080`, built by `FUN_100481180`). |

Link flags: 0x10 = no server lists or window streams (this client), 0x20 =
never transmit (and a request with it opens no link), 0x400 = ignore input.

**Keepalive.** Hellos (and types 6, 0x1d) refresh the link. MagicQ closes a
link idle for ~1 s. It also closes any link idle for ~166 ms when another
request arrives (`FUN_1001612b0`), so the client sends a hello every 50 ms.
These are sys-tick units, assumed to be ms (unconfirmed).

**Input (0x10).** u16 target window at 0x0a (1..0x2e3; remapped for peers
below version 8), then 20 bytes at 0x0c..0x1f, each XORed with
`key[0x1f - offset]` (key at `0x101e2d760`). The subtype is split between
bytes 0x0f (low) and 0x14 (high), and the mods between 0x11 (low) and 0x12
(high). Values A and B are scattered one bit per byte: bit `j` sits at bit
position `j % 8` of these bytes:

```
A: 19 16 0e 1d 1a 1c 10 1b 18 15 17 13 0d 1e 0c 1f
B: 1b 19 16 0e 1d 1a 1c 10 1f 18 15 17 13 0d 1e 0c
```

All other bits are random filler. Subtype 0 (keyboard key) sends the target
window its select command (`0x12e`, which also opens it) first. Subtype 4
(console button, A = board button index, B = 1 pressed / 0 released) goes
straight to `FUN_1004fad20`, the handler for the console's own buttons, and
selects no window. Board indices (table at `0x101e365d0`, keycode = 0x100 +
index): Flash n = n-1, Pause n = 9+n, Go n = 19+n, Select n = 38+n.

**Gates on the console.** Input is dropped unless remote control is enabled
(`DAT_10228b394`) and the licence is unlocked for remote control
(`FUN_10005afc0(0xc)`, "Remote request - not unlocked"). Before each input
MagicQ calls `FUN_100446ba0(1)`, which re-lays out windows too small for
their content. Its visible effect on a console is unconfirmed.

**Screen sync (window streams).** Without link flags 0x10/0x400, the type
0x06 handler (`FUN_10016e5d0`) calls `FUN_100481b30`, which dumps the
console's screen to that link. MagicQ's own controller sends type 0x06
with flags `0x0005`, monitor 0 (`u16 flags`, `u16 monitor`) every ~80 ms,
and each one gets a full dump (~25 KB on the test console). A dump holds:

- type 0x0f status (`FUN_10047f480`): `u16` at 0x10 is the console's
  selected window (`FUN_100446430`, a window table index as in CHWP, 0x6d
  = none), then the message and command lines.
- type 0x0e widget text (`FUN_10047ffe0`): soft keys (widgets 200+, 400+)
  and the playback strips above the on-screen faders (widget
  300 + playback - 1, one per strip on screen, 10 on MagicQ PC):
  `u16 widget`, `u16 kind` (2), `u16` at 0x0e, `u32` at 0x14, `u32 flags`
  at 0x18 (low byte 1 active, 2 idle), then five cstrings from
  `FUN_100524340`: label (`PB10 SP2`), name (stack, or the speed master's
  name), current (cue text, or `%.1f BPM` for a speed master), progress
  (`ACT`, `(n)`, fade %, pickup arrow), next (next cue text, or the
  multiplier `x2 `/`/%i `/`x%i ` and `Running`/`Halted`). Frames carry
  stale bytes after the strings.
- each window whose flags (`+0x14`) have 0x8001 set (open on a monitor),
  or bit 0 with link flag 1: type 7 layout (`FUN_10047fce0`), type 9 title
  and column headers (`FUN_10047f620`), type 8 one cell each
  (`FUN_10047f790`, from the cell cache at `+0x8678`, only the visible
  rows and columns). The cell strings are the same three as CHWP 0x8007,
  so for windows CHWP 0x08 is enough (it reads any window, on screen or
  not).
- types 0x0a, 0x11, 0x12, 0x1c, 0x31 (not decoded), and playback wing
  display blocks (type 0x2e) only for connected physical wings.

**Confirmed live** (MagicQ 1.9.7.3, capture of a MagicQ controller and
`remote_control_example.dart <ip> sync`): the strips carry every
playback's current and next cue text and, for speed master stacks,
`PB10 SP2 | Int SPM | 127.9 BPM | ^ | Running`, updating as the tempo is
tapped or faded; the status carries the selected window. A multiplier was
not set during the capture, so its text is from the binary only.
`MagicQRemoteControl(screenSync: true)` asks for a dump every 250 ms and
reads the strips (`ChmqPlaybackStrip`, `SpeedMasterInfo`) and status
(`ChmqStatus`).

Cue names: the playback scribble builder (`FUN_100524340`) and the Cue
Stack window (`FUN_100355230`, column 2 = step text at step `+4`) have
them. With screen sync, the strips carry the running and next cue's text
for every on-screen playback. Without it, neither reaches a remote for
every playback: the Playbacks window shows them only in its status view
(view 4, which MagicQ PC without wing hardware forces back to view 0;
confirmed live, it comes back empty), and the Cue Stack window follows the
console's selected playback (`DAT_102083f70`) unless locked. Execute
"Playback info" items (`FUN_100367520`, text `T-PB<n>`) do carry the
current cue text over CHWP.

An earlier client collected cue lists by pressing each playback's Select
button (board button 38+n) and reading the Cue Stack window. In its
default view the 0x8008 headers name the columns (table at `0x101c264ac`:
"Cue id", "Cue text", "Wait", "Halt", "Delay", "Cue", "Next cue", ...); a
window locked to a stack (`+0x94b4` set) doesn't follow the selection.
The strips made that unnecessary, and it was removed because it changes
the console's selection.

The app's cue picker does the same for one playback, only when the user
opens it: Select (board button 38 + n) over CHMQ, then
`MagicQClient.readCueStack()`, which requests the Cue Stack window and
parses it with `CueStackReader` ("Cue id" and "Cue text" columns, item =
step * columns + column, the row after the last step reads `End`). The
window reads the stack live on each request (`FUN_100355230` checks
`DAT_102083f70` every call), and a CHWP 0x08 request has no field to pick
a stack. From the binary only: whether the window's item count (`+0x70`)
covers every step of a long stack.

Measured live: the window switches to the new stack ~0.8-0.9 s after the
Select press (the cause, slow CHMQ input handling or the selection
itself, is unconfirmed), so a read 250 ms after the press returns the
previously selected stack. The title is `CUE STACK (CS<n>: <name>)` for a
named stack (the unnamed form is unconfirmed). The client reads the
title, presses Select, polls the header with
`MagicQClient.waitForCueStackTitle()` until the title changes, and only
then reads the steps. When the title already shows the playback's stack
(its strip name, or its last read list's title), it skips the wait.
`example/remote_control_example.dart <ip> cues <pb> [cue]` tests it, and
`<ip> selectlag <pb>` times the switch.

Checked on MagicQ 1.9.8.3 (macOS, demo mode, loopback): the console
answers the request, the link comes up, and a button press gets as far as
the unlock gate (the console shows "Remote request - not unlocked"). So the
framing and masking are accepted. Not yet confirmed on a licensed console: that button presses act natively, and that the selected window
stays put. Test with `example/remote_control_example.dart` from another
machine.

## Window focus

CHWP Execute presses don't change the console's selected window: MagicQ
saves the Execute window's page and cursor, runs the press
(`FUN_1004562c0(0x1b, ...)`), and restores them. Presses still combine with
console-wide pending modes (e.g. an operator mid Copy or Set), like a local
press would. Execute page-navigation items (type 0xb items) only change the
phone's own Execute page. Console keys (0x02) act on whichever window is
selected, by design.
