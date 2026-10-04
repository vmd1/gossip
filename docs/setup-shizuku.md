# Setting up Shizuku

[Shizuku](https://shizuku.rikka.app/) is a free app that lets other apps use Android's powerful "shell" privileges without rooting your phone. Gossip uses it for a few features that Android does not allow a normal app to do.

**Shizuku is heavily recommended.** Gossip runs without it, but without it you lose screen mirroring, Universal Control, Instant Hotspot on Android 16 and newer, and background clipboard reading — the features that set Gossip apart. Set it up once, and restart it after each reboot of the device.

## What needs Shizuku

- **Screen mirroring** — Gossip starts a small bundled server (a pinned build of [scrcpy](https://github.com/Genymobile/scrcpy)) at shell level to capture the screen and inject input
- **Universal Control** — Gossip creates a virtual mouse and keyboard on the device at shell level
- **Instant Hotspot on Android 16 and newer** — Android 16 only lets privileged callers start tethering
- **Background clipboard reading (optional)** — text only; without it clipboard sync still works while Gossip is in the foreground

Everything else — notification mirroring, Do Not Disturb sync, media control, lock on leave, find my device, battery sync, and Instant Hotspot on Android 10–15 — works **without** Shizuku.

## What Shizuku is (and isn't)

- no root needed
- it runs a small background service that Gossip talks to, after you give Gossip permission
- it must be restarted after every reboot of the device (unless the device is rooted)
- it only does what the apps you authorise ask for — you can revoke Gossip in Shizuku's app list at any time

## 1. Install Shizuku

- **Google Play:** [Shizuku on Google Play](https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api)
- **GitHub:** [Shizuku releases](https://github.com/RikkaApps/Shizuku/releases) — download the latest APK and install it
- project page: [shizuku.rikka.app](https://shizuku.rikka.app/) · source: [RikkaApps/Shizuku](https://github.com/RikkaApps/Shizuku)

## 2. Turn on Developer options

- open **Settings → About phone** (on some devices **About phone → Software information**)
- tap **Build number** seven times until it says developer mode is on
- you now have **Settings → System → Developer options** (the location varies by manufacturer)

## 3. Start Shizuku

Pick the method that fits your device. The official guide is [Shizuku: Setup](https://shizuku.rikka.app/guide/setup/).

### Android 11 or newer: wireless debugging (no computer needed)

- connect the device to **Wi-Fi** (wireless debugging needs a network connection)
- in **Developer options**, turn on **Wireless debugging**
- open the Shizuku app and choose **Start via Wireless debugging**
- pair once:
  - in Developer options, open **Wireless debugging → Pair device with pairing code**
  - Shizuku shows a notification; reply to it with the six-digit pairing code
  - tip: use split-screen or a floating window so the pairing dialog stays visible while you type
- back in Shizuku, tap **Start**; the status changes to **Shizuku is running**
- you only pair once, but you must **start Shizuku again after every reboot**

### Android 10 or older, or if wireless debugging is not available: a computer with adb

- install Google's [SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools) on the computer
- on the device, turn on **USB debugging** in Developer options and connect it with a USB cable (accept the debugging prompt)
- run:

```bash
adb shell sh /sdcard/Android/data/moe.shizuku.privileged.api/start.sh
```

- repeat after every reboot

### Rooted devices

- start Shizuku directly from its app; it can start on boot if you allow background execution

## 4. Give Gossip permission

- open Gossip and use the **Shizuku (heavily recommended)** step in setup (or the matching row under **Settings → Permissions**)
- when Shizuku asks whether to allow Gossip, choose **Allow**
- Gossip tracks four states: Shizuku not installed, installed but not running, running but Gossip not allowed yet, and ready — the setup row shows which one you are in

## 5. Check that it works

- **Shizuku app:** it should say "Shizuku is running" and list Gossip as authorised
- **Mac:** open the device list and click **Mirror** next to the device — a mirror window should open
- **Universal Control:** after placing the device in **Arrange Devices…** its card should show **Ready** (see [Universal Control](universal-control.md))

## After a reboot

- the phone or tablet forgets that Shizuku was started
- open Shizuku and start it again (wireless debugging takes a few seconds; the adb method needs the computer)
- Gossip reconnects on its own once Shizuku is back

## Instant Hotspot without Shizuku (Android 10–15)

- on Android 10–15 Instant Hotspot works without Shizuku, but Gossip needs one extra permission that only a computer can grant
- with USB or wireless debugging on, run once:

```bash
adb shell pm grant dev.vmd1.gossip android.permission.WRITE_SECURE_SETTINGS
```

- then use **Settings → Instant Hotspot** (or **Test Hotspot Methods** in setup) to see which method works on your phone
- on Android 16 and newer this is not enough — Shizuku must be running

## If Shizuku keeps stopping

- tips from the Shizuku community wiki ([thedjchi/Shizuku wiki](https://github.com/thedjchi/Shizuku/wiki)) for when Shizuku stops unexpectedly
- **Samsung devices**
  - open the phone dialler and dial `*#0808#`
  - select **MTP + ADB** (even if it already looks selected), then tap **OK**
- **Other devices**
  - go to **Developer options → Default USB configuration** and set it to **Charging only**
- start Shizuku again afterwards (step 3)
- more tips are listed on the wiki linked above

## Optional: a community fork with auto-restart

- [thedjchi/Shizuku](https://github.com/thedjchi/Shizuku) is a community **fork** of the official [RikkaApps/Shizuku](https://github.com/RikkaApps/Shizuku)
  - a **watchdog** that automatically restarts Shizuku if it stops unexpectedly
  - waits for a Wi-Fi connection before starting the service
  - a TCP mode, so wireless debugging does not need continuous connectivity
  - start/stop intents for automation apps such as Tasker
  - beta features: a stealth mode that hides Shizuku from other apps, and auto-updates
- download it from [its GitHub releases](https://github.com/thedjchi/Shizuku/releases) (it is not distributed on Google Play)
- **a few cautions**
  - it is a third-party app that runs with elevated privileges, so only install it if you trust its maintainer
  - it is not part of Gossip, and Gossip has not been tested against it — Gossip uses Shizuku's standard API
  - if you are unsure, use the official app

## Common problems

- **Shizuku says "not running" after a reboot** — start it again (step 3)
- **Shizuku stops on its own** — try the USB tips in [If Shizuku keeps stopping](#if-shizuku-keeps-stopping), or the [auto-restart fork](#optional-a-community-fork-with-auto-restart)
- **Wireless debugging turns itself off** — it needs Wi-Fi; some devices switch it off when they leave the network, so reconnect and start Shizuku again
- **The pairing code prompt disappears** — open the pairing dialog in split-screen or a floating window so it stays on screen
- **Gossip does not show up in Shizuku's authorised list** — open Gossip's Shizuku setup row so it requests permission
- **More fixes:** [Troubleshooting](troubleshooting.md)
