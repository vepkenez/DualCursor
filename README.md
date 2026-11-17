# DualCursor

A small macOS menu-bar app that gives each pointing device its own cursor position. Use the
trackpad, switch to the mouse, and the cursor jumps back to where the mouse left it, and the
other way round. Works with any number of pointing devices. macOS 13+.

## How it works

- **IOHIDManager** watches raw HID input, so the app knows which device just produced
  activity. Normal pointer events don't say which device moved the cursor.
- A **CGEvent tap** sees each pointer move and click. When the device behind it isn't the one
  last used, the app saves the cursor position for the old device and warps the cursor to the
  new device's saved position.
- Real movement and button presses win over mere touch-surface contact, so a palm resting on
  the trackpad doesn't take the cursor while you use the mouse.

It needs **Input Monitoring** (to read HID input) and **Accessibility** (for the event tap).
All of the code is in [`Sources/main.swift`](Sources/main.swift). Installing a shared copy:
[INSTALL.md](INSTALL.md).

## The Ouija effect

Move both devices at the same time and the cursor looks possessed. There is still only one
real cursor, and each move is credited to whichever device moved most recently, so it swaps to
the other device's saved spot, takes a step, and swaps back, many times a second. Both devices
keep their own paths, and the one cursor flickers between them like a planchette with two sets
of fingers on it. It's harmless and stops as soon as you use one device at a time; just don't
click mid-séance, because the click lands wherever the cursor is at that instant.

## Build

```bash
./build.sh      # build and install to ~/Applications (your Mac's architecture)
./package.sh    # universal build + dist/DualCursor-<version>.dmg to share
```

Both sign ad-hoc. That means each rebuild looks like a new app to macOS, so you'll need to
re-grant the two permissions, and shared copies need "Open Anyway" once (see
[INSTALL.md](INSTALL.md)).

Debug output: run `~/Applications/DualCursor.app/Contents/MacOS/DualCursor --log` from a terminal.
