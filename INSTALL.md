# Installing DualCursor

DualCursor gives your trackpad and your mouse their own cursor position. Use the trackpad,
switch to the mouse, and the cursor jumps back to where the mouse left it, and the other way
round. It works with any number of pointing devices. Needs macOS 13 (Ventura) or later.

## Install

1. Drag **DualCursor** into the **Applications** folder.
2. Open it from Applications. macOS will block it, because it is a small hobby app that isn't
   registered with Apple. Click **Done** (not "Move to Trash").
3. Open **System Settings → Privacy & Security**, scroll down to the message about DualCursor
   being blocked, and click **Open Anyway**. Confirm with your password or Touch ID.
4. When DualCursor opens it asks for two permissions. Turn DualCursor on in both:
   - **Privacy & Security → Input Monitoring**, to tell which device you moved
   - **Privacy & Security → Accessibility**, to move the cursor

   If it asks you to quit and reopen after Input Monitoring, do that.

A small cursor icon appears in the menu bar. Done.

## Using it

- The first time you use each device, the cursor stays where it is. From the next switch on,
  each device gets its own position back.
- Clicking or tapping without moving also switches.
- A palm resting on the trackpad won't take over while you're using the mouse.

The menu bar icon has:

- **Enabled**: turn it off for a while
- **Forget Saved Positions**
- **Launch at Login**: start it automatically
- **Quit DualCursor**

If the menu shows "⚠︎ Needs: …", a permission is still missing. Use **Open Privacy
Settings…** from the same menu.

## Using both at once: the Ouija effect

Move the trackpad and the mouse at the same time and the cursor seems to be steered by an
unseen hand. One device wins the cursor, and the other device's saved spot gets overwritten
with the winner's position, so both devices end up in the same place. From there they take
turns: each move nudges the one cursor onward from wherever the other device just left it,
like a planchette with two people's fingers on it.

Nothing breaks when this happens. Go back to using one device at a time and each one carries
on with its own position again, starting from that shared spot. (A click while both are
moving lands wherever the cursor happens to be at that instant, so don't do that on anything
important.)

### Party trick: a group séance

DualCursor doesn't stop at two. Plug in three, four or more mice, hand one to each person,
and the whole group controls the computer together: with everyone moving at once, all the mice
end up sharing one spot and take turns nudging the cursor from wherever the last person left
it. Try steering it, together, to spell out a
word on the on-screen keyboard, close a window, or draw something in a paint app, and see
whether the group can agree on anything at all. (A USB hub helps; Bluetooth mice work too.)

## Uninstall

Quit it from the menu bar (turn off **Launch at Login** first if you turned it on) and move
DualCursor from Applications to the Trash. You can also remove it from the Input Monitoring
and Accessibility lists.
