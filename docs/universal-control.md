# Universal Control

Use your Mac's mouse and keyboard on a paired Android phone or tablet. Push the cursor off the edge of the Mac's screen towards a device you placed in the layout and it carries on there.

## Requirements

- **Mac:** Gossip running, with **Accessibility** and **Input Monitoring** permission (see below)
- **Android device:** [Shizuku running](setup-shizuku.md) and Gossip allowed in it
- **Connection:** the device must be **directly** connected to the Mac on the same network
  - a device shown with a **blue** icon (reachable only through another device) cannot be controlled
- **Switch:** Universal Control must be on in **Settings → Features** on the device, and in the Mac's **Settings…** (the Features list and the Universal Control section)
  - a device with it off refuses sessions and shows an error on the Mac

## Set it up

- grant the two Mac permissions
  - **System Settings → Privacy & Security → Accessibility** and **Input Monitoring**: add or enable Gossip
  - Gossip's Settings pane has buttons that open both
  - if the permission is missing, **Arrange Devices…** shows a banner saying input capture is not running
- on the Mac open **Settings… → Universal Control → Arrange Devices…**
  - paired Android devices start on a **shelf** along the bottom
  - drag a device next to an edge of your Mac's screen; it snaps to the edge
  - drop a device near an edge and it attaches (it does not need to be exact)
  - you can place several devices; they stay connected in parallel and the cursor can move from one to the next
  - drag a device back onto the shelf to take it out of the layout
  - each card shows the device's real screen shape and its state (**Ready**, **Connecting…**, or the reason it failed)
- push the cursor off the matching edge of your Mac's screen

## Using it

- **Mouse and trackpad:** move, click, right-click, scroll
- **Keyboard:** typing, shortcuts and non-ASCII text all work
  - **Settings… → Universal Control** chooses what ⌘ becomes on the device: **Control** (so ⌘C copies) or the **Meta/Windows key**
  - it also chooses how typing is sent: **Characters** (best for non-US layouts) or **Key codes**
- **Navigation shortcuts** (while the pointer is on the device)
  - ⌘1 — Home
  - ⌘2 — App Switcher
  - ⌘3 — Notifications
  - ⌘[ — Back
- **Waking the screen:** if the device's screen is off when the cursor arrives, it wakes (a locked device wakes to its lock screen, and the cursor works there)
- **Trackpad gestures** (three-finger swipes, pinch and so on) are ignored while the pointer is on a device, so they do not trigger Mission Control or Spaces on the Mac
- **Getting back:** push the cursor back across the shared edge, or press **Control + Option + Command + Esc** to jump back to the Mac immediately

## Good to know

- **Cursor and keyboard on the device:** Gossip creates a virtual mouse and keyboard on the device when you cross, so Android shows a real cursor and hides the on-screen keyboard
  - they stay for about 8 seconds after you leave, so crossing back is instant, then they are removed
  - the first crossing after being away takes a moment (about 0.8 s) while they are created
- **Password fields:** macOS hides keystrokes in secure password fields from every app, so typing into them from the Mac does not work
- **Pointer speed:** Android speeds the cursor up on its own depending on how fast you move
  - Gossip asks the device where its real cursor is whenever you approach an edge that leads somewhere, so hand-back happens at the real edge
- **Safety nets:** the cursor returns to the Mac automatically if the session drops, when the Mac sleeps, locks or quits, or if you turn the feature off
- **Layout:** your arrangement is saved and restored; Mac display changes are handled (a device that no longer touches a screen is moved back to the shelf)
- **Direction:** Mac → Android only; controlling the Mac from an Android device is not possible

## If the mouse stutters

- almost always Wi-Fi latency, not Gossip
  - macOS briefly steps off your Wi-Fi channel for AirDrop/Handoff (a feature called AWDL), which delays traffic for tens of milliseconds
  - some phones also let their Wi-Fi radio doze, which causes the same effect
- things to try
  - use a wired connection for the Mac, or connect it to a 5 GHz network
  - temporarily turn AWDL off (AirDrop, Handoff and Sidecar stop working until you turn it back on or reboot):

```bash
sudo ifconfig awdl0 down
sudo ifconfig awdl0 up    # to turn it back on
```

- more help: [Troubleshooting](troubleshooting.md#universal-control)
