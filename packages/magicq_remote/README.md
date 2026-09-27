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
dumps a console's current Execute page.

## Console setup

- CHWP: Setup, "Enable remote app". If MagicQ has users configured, pass
  `user`/`password`.
- CREP: Setup, "Ethernet remote protocol" = `ChamSys Rem (tx + rx)`, port
  6553 ("Ethernet remote port"). `(rx)` alone works too, without feedback.
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
| 0x08 / 0x09 window | → | window id (≤ 0x33), first row, row count | `FUN_100543870`, `FUN_100543d60` |
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
  u16 borders  bit7 fader spans the cell below, bit9 cell is that lower half
  u32 extra    bit7 active (colour mode)
  u32 state    1 active / 2 inactive; colour mode: 0x80000000 | RGB
  u32 icon id  (0xfd000000 = bitmap named by tag)
  u16 level    0..255
  cstring text, cstring name, cstring tag ("PB", "CS", "FL", "LVL", ...)
```

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
| `nP`    | playback page |

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

On a standalone console (multi-console sync `DAT_10228b400` = 0) a playback
is only reported if its cue stack has flag `+0x94` bit 0 set, most likely
the cue stack option "Send playback state to other consoles". To be
confirmed on a console.

## Full remote control (multi-console protocol)

MagicQ's "Remote control another MagicQ" uses the multi-console network
protocol (dispatcher `FUN_10016e8d0`, about 65 message types), not CHWP. The
controlled console streams each window as geometry, title, column headers
and text rows (types 7, 8, 9, ...), and the controller sends raw input in
type 0x10 (`FUN_100482080`): keys, mouse, touch and encoders, with
XOR-masked fields. Findings that decided against using it here:

- Every input carries a target window ID, and MagicQ sends that window its
  select command (`0x12e`, which also opens it) before acting. So remote
  keys and clicks change the console's selected window.
- The controlled MagicQ must be unlocked for remote control ("Remote
  request - not unlocked"), and the protocol is tied to multi-console
  sessions and version checks.
- It mirrors MagicQ's desktop windows, which don't suit a phone.

## Window focus

CHWP Execute presses don't change the console's selected window: MagicQ
saves the Execute window's page and cursor, runs the press
(`FUN_1004562c0(0x1b, ...)`), and restores them. Presses still combine with
console-wide pending modes (e.g. an operator mid Copy or Set), like a local
press would. Execute page-navigation items (type 0xb items) only change the
phone's own Execute page. Console keys (0x02) act on whichever window is
selected, by design.
