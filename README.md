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

Move both devices at the same time and the cursor looks possessed. One device wins, and the
other device's saved position gets overwritten with the winner's, so both end up in the same
place. From then on they take turns: each move pushes the one cursor onward from wherever the
other device left it, like a planchette with two sets of fingers on it. It's harmless; go back
to one device at a time and each carries on with its own position from that shared spot. Just
don't click mid-séance, because the click lands wherever the cursor is at that instant.

(Why it merges: during rapid switching, a pointer event can still carry a location worked out
before the last warp, so the position saved for the outgoing device is really the other
device's spot.)

It also makes a decent party game. Plug in three or more mice, give one to each person, and
have the group steer the one cursor together: spell a word on the on-screen keyboard, close a
window, draw something. With everyone moving, all the mice share one spot and take turns
nudging it, so the result is a lot like a real Ouija board.

## Build

```bash
./build.sh      # build and install to ~/Applications (your Mac's architecture)
./package.sh    # universal build + dist/DualCursor-<version>.dmg to share
```

Both sign ad-hoc. That means each rebuild looks like a new app to macOS, so you'll need to
re-grant the two permissions, and shared copies need "Open Anyway" once (see
[INSTALL.md](INSTALL.md)).

Debug output: run `~/Applications/DualCursor.app/Contents/MacOS/DualCursor --log` from a terminal.
