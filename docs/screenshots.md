# Screenshots

Android screenshots in `site/img/` are real (emulator, API 36, fresh install, default theme). The hero (`site/hero.svg`) and icons are drawn illustrations, The Mac menu and Settings shots are real too. The QR code in `mac-pairing.png` is blurred on purpose: never publish a live pairing code. Still wanted:

**Capture rules:** use paired test devices with generic names, no real notifications or clipboard contents, light and dark if possible, Retina PNG (or WebP), under about 300 KB each. Put web images in `site/img/`; the relay serves every file in `site/` from startup, so no other change is needed.

| File | Shot |
|---|---|
| `arrange-devices.png` | Settings → Universal Control → Arrange Devices… with a phone and tablet placed |
| `mirroring.png` | The borderless mirroring window with the phone's home screen |
| `notifications.png` | A mirrored notification with the inline reply field |

Once the files exist, add them to `site/index.html` (extend the gallery) and to the README under **Features**.
