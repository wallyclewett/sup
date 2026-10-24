# Sup

A macOS menu bar app for a **Desky** standing desk (Jiecang controller with the Desky Bluetooth adaptor).
The name is a joke: **S**tand-**U**p **P**addle, so the icon is a paddle.

## What it does

- **Right click** the paddle: the desk stands up, or sits down if it is already up.
- **Left click**: a menu with
  - a timer for how long you have been sitting or standing
  - today's standing and sitting time, and a daily standing goal with a progress bar
  - the last 7 days (a ✓ on days that reached the goal)
  - a height slider (the desk moves when you let go)
  - your 4 presets, with names and heights
- **Reminders**: "Time to stand up" at :50 and "Time to sit down" at :00, only inside your hours.
  The button on the popup moves the desk to the preset you choose.
- **Settings**: open at login, goal, reminder hours and presets, preset names and heights.
- Time is not counted while the Mac is locked, in the screen saver or asleep.

The menu bar icon is filled while you stand and outlined while you sit.

## Build

Needs macOS 14 or later and Xcode (for `swiftc` and `actool`).

```bash
./build.sh
```

This builds `~/Applications/Sup.app` and opens it. Allow Bluetooth and notifications when macOS asks.

To change the app icon, edit `make_icon.swift`, then run `./build_icon.sh` and `./build.sh`.

## Use it with your own desk

The app looks for one desk. Change these two values near the top of `main.swift`:

- `deskID`: your desk's Bluetooth ID on your Mac
- `"WallyDesk"`: your desk's Bluetooth name

## Protocol

Bluetooth LE service `FE60`, write to `FE61`, notifications on `FE62`.
Commands are `F1 F1 <command> <length> <data> <checksum> 7E`, where the checksum is the sum of the command, length and data bytes.

| Command | What it does |
|---|---|
| `05`, `06`, `27`, `28` | Move to preset 1, 2, 3, 4 |
| `07` | Ask for the height |
| `1B 02 <mm high> <mm low>` | Move to a height in millimetres |

The desk reports its height as `F2 F2 01 03 <mm high> <mm low> ...`.

This protocol comes from the Desky and Jiecang community. Other desks with similar controllers can act differently, so test with care.

## Files it writes

- `~/desk-control/standup_log.json`: standing and sitting seconds per day
- `~/desk-control/standup_sessions.csv`: one line for each time in one position

## Licence

MIT licence. See [LICENSE](LICENSE).
