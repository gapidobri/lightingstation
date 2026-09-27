# Lighting Station

Live remote control for ChamSys MagicQ, in the spirit of Mixing Station:
touch faders and a mirror of the console's Execute window, built for
running a show rather than setting one up.

- `lib/`: the Flutter app (widgets only, no Material).
- `packages/magicq_remote/`: the protocol package. Its README documents
  both MagicQ protocols.

## Run

```sh
flutter run                          # connect to a console
flutter run --dart-define=DEMO=true  # offline demo, no console needed
```

The app must run on a different device than MagicQ, because both need UDP
port 4920. On the console, turn on "Enable remote app". For the playback
faders, also set "Ethernet remote protocol" to "ChamSys Rem (tx + rx)". The
"tx" part makes MagicQ report playback levels, activity and cues back; on a
standalone console only for cue stacks with the option "Send playback state
to other consoles".

iOS: discovery broadcasts need the `com.apple.developer.networking.multicast`
entitlement. Without it, enter the console address by hand.
