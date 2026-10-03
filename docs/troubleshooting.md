# Troubleshooting

Find your symptom, try the fixes in order. If nothing helps, see [Getting logs](#getting-logs) and open an issue.

## Devices can't find or connect to each other

- **Check the basics**
  - both devices are on the **same Wi-Fi or LAN** (not a guest network, not mobile data)
  - Gossip is running on both (the Mac icon is in the menu bar; Android shows a sync notification)
  - Wi-Fi is on, and a VPN is not routing local traffic elsewhere
- **Router blocks device-to-device traffic**
  - "client isolation", "AP isolation" and most guest networks stop devices talking to each other, and also block discovery
  - turn that setting off, or put both devices on the main network
- **macOS Local Network permission**
  - **System Settings → Privacy & Security → Local Network** → make sure Gossip is switched on
- **Discovery works but the connection doesn't**
  - restart Gossip on both devices
  - toggle Wi-Fi off and on on the Android device
- **Devices are on different networks**
  - set a **Fallback IP** (for example a Tailscale address) in the Mac's device menu so Gossip dials it directly
- **The icon is blue, not green**
  - blue means "reachable through another device only"; the features that need a direct link (Universal Control, screen mirroring) will not work until it turns green
  - move both devices onto the same network and wait a minute

## Pairing fails

- check the QR code is fully visible and the camera has permission (Android: allow the camera when asked)
- make sure both devices are on the same network while pairing
- confirm on **both** screens — an unconfirmed pairing times out
- still failing: **Forget This Device…** on both sides, restart Gossip on both, then pair again
- a device you removed on purpose will not reconnect on its own — pair it again

## The Android side stops syncing in the background

- Gossip runs as a foreground service; some phones kill background apps aggressively
- set Gossip to **Unrestricted** battery use (usually **Settings → Apps → Gossip → Battery**) and turn off "put unused apps to sleep" for it
  - the wording and place differ by manufacturer — [dontkillmyapp.com](https://dontkillmyapp.com/) lists the steps for each brand
- keep the persistent Gossip notification enabled; hiding it can let the system stop the service

## Notifications

- **Phone notifications don't show on the Mac**
  - Android: grant **Notification access** to Gossip (**Settings → Notifications** in Gossip) and allow **Post notifications**
  - check the app you expect is in the forwarded list (**Settings → Notifications → Forwarded apps**)
  - Mac: click **Open Notification Settings…** in Gossip and allow notifications for Gossip
  - make sure **Notifications** is on in **Settings → Features** on both devices
- **Replies don't send**
  - the original app has to be able to reply from a notification; if its notification has no reply field on the phone, Gossip cannot add one
- **Notifications are dropped silently**
  - on Android, without the **Post notifications** permission the system discards mirrored notifications without any error

## Clipboard

- **Text syncs but not while Gossip is in the background (Android)**
  - Android only lets the foreground app read the clipboard; the optional background reader needs [Shizuku](setup-shizuku.md) (text only)
- **Nothing syncs**
  - check **Clipboard** is on in **Settings → Features** on both devices
  - text and images (as PNG) sync

## Do Not Disturb sync

- **Android doesn't follow the Mac (or the other way round)**
  - grant **Do Not Disturb access** on Android (setup screen, or **Settings → Permissions**)
  - on the Mac, complete **Do Not Disturb Sync Setup…** — the Shortcuts must exist with exactly the names shown (`Connect Turn On DND`, `Connect Turn Off DND`), and the two automations must have **Ask Before Running** off
  - see [Getting started](getting-started.md#mac-do-not-disturb-sync)

## Lock on leave

- Bluetooth permission must be granted on both devices
- on the Android device that should be locked, grant **Device admin** (setup screen)
- the phone has to be paired and the feature switched on for that specific device

## Instant Hotspot

- **Android 16 and newer:** [Shizuku](setup-shizuku.md) must be running and Gossip allowed in it
- **Android 10–15:** run `adb shell pm grant dev.vmd1.gossip android.permission.WRITE_SECURE_SETTINGS` once (see [Setting up Shizuku](setup-shizuku.md#instant-hotspot-without-shizuku-android-1015))
- run **Test Hotspot Methods** (setup screen, or **Settings → Instant Hotspot** on the phone) to see which method works on your phone
- the Mac needs **Location Services** allowed for Gossip so it can join the hotspot automatically

## Screen mirroring

- **Mirror does nothing or fails**
  - [Shizuku](setup-shizuku.md) must be **running** (it stops after a reboot) and Gossip allowed in it
  - the device must be reachable from the Mac
  - check **Screen mirroring** is on in **Settings → Features** on the device
- **No audio**
  - audio capture depends on the Android version and the app being mirrored; some apps block it

## Universal Control

- **Dragging to the edge does nothing**
  - the device card in **Arrange Devices…** must say **Ready**; if it says **Connecting…** or shows an error, fix that first
  - a banner at the top of **Arrange Devices…** means input capture is not running — see "Accessibility looks on but Gossip says it isn't" below
  - the device must be placed so one of its edges touches your Mac's screen, and you must push on the matching edge of the Mac
  - the device must be directly connected (green icon), with Shizuku running
- **"Connecting…" then "device didn't respond"**
  - the device is running an older Gossip build without Universal Control — update it to the same release as the Mac
  - or Universal Control is switched off on the device (**Settings → Features**)
  - or the device is not reachable directly
- **Accessibility looks on but Gossip says it isn't**
  - macOS ties the permission to the app's code signature, so after you replace the app with a differently signed build the switch can look on while the new app is not covered
  - in **System Settings → Privacy & Security → Accessibility** (and **Input Monitoring**), select Gossip, click **−** to remove it, reopen Gossip, and add it again
  - or reset it from Terminal, then reopen Gossip and approve the prompts:

```bash
tccutil reset Accessibility dev.vmd1.gossip.Gossip
tccutil reset ListenEvent dev.vmd1.gossip.Gossip
```

- **A second pointer appears on the Mac**
  - update to a build that includes the gesture fix (three-finger swipes used to hand the cursor back to macOS)
  - press **Control + Option + Command + Esc** to jump back to the Mac if things get confused
- **The mouse stutters or jumps**
  - almost always Wi-Fi latency — see [Universal Control](universal-control.md#if-the-mouse-stutters) for the AirDrop/AWDL explanation and what to try
- **The cursor leaves the device early or late**
  - Android accelerates the cursor by an amount that depends on timing; Gossip corrects for it near the edges, but a very slow network can lag behind
- **Typing into a password field doesn't work**
  - macOS hides secure input from all apps; this is expected
- **The device's screen is off**
  - the cursor entering should wake it; if it doesn't, check Shizuku is running

## Shizuku

- **Shizuku is not running** — it stops after every reboot; start it again ([Setting up Shizuku](setup-shizuku.md#3-start-shizuku))
- **Shizuku keeps stopping on its own** — see [If Shizuku keeps stopping](setup-shizuku.md#if-shizuku-keeps-stopping) for the USB-setting tips and an optional community fork with a watchdog
- **Gossip is not listed in Shizuku** — open Gossip's Shizuku setup row so it asks for permission, then choose **Allow**

## Mac app issues

- **No icon in the menu bar**
  - Gossip is a menu-bar app with no Dock icon; a crowded menu bar can hide it (check the notch area or a menu-bar manager)
  - make sure it is running: `pgrep -fl Gossip`
- **Gatekeeper blocks the app**
  - **System Settings → Privacy & Security → Open Anyway**, or `xattr -dr com.apple.quarantine /Applications/Gossip.app`
- **The app won't launch after an update**
  - quit any old copy from the menu bar or Activity Monitor, then open the new one
  - only one copy can run at a time

## Android app issues

- **"App not installed" when updating**
  - Android only accepts an update signed with the same key as the installed app; uninstall the old build first (you will need to pair again)
- **Install is blocked**
  - allow "install unknown apps" for the app you opened the APK with
- **The setup screen keeps appearing**
  - grant or skip each permission, then tap **Finish**; you can rerun it from **Settings → Devices & pairing**

## Getting logs

- **what the downloaded (release) apps log**
  - they log failures only: warnings and errors on Android, error-level messages on the Mac
  - they deliberately do not log routine activity, addresses, device names or network names
  - for full detail, run a debug build ([Building and signing](building-and-signing.md)); debug builds log everything
- **Mac**
  - open **Console.app**, select your Mac, and filter on `Gossip`
  - or stream from Terminal:

```bash
log stream --predicate 'process == "Gossip"' --info
```

- **Android** (with USB or wireless debugging on, from a computer):

```bash
adb logcat | grep -i gossip
```

- include
  - macOS and Android versions, device models, and the Gossip release number (in Android's app info and in the Mac app's Get Info)
  - what you expected, what happened, and the lines around the first error
- open an [issue](https://github.com/vmd1/gossip/issues)

## Resetting

- **One device:** **Forget This Device…** in the device menu, then pair again
- **Everything on the Mac:** quit Gossip and remove `~/Library/Application Support/Connect` — this deletes its identity and trusted devices, so every device has to pair with the Mac again
- **Everything on Android:** **Settings → Apps → Gossip → Storage → Clear data**, or uninstall and reinstall
