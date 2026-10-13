# Screenshots

The README and website currently use drawn illustrations (`site/hero.svg`, `site/icons.svg`), not real screenshots. This is the shot list for replacing them.

**Capture rules:** use paired test devices with generic names, no real notifications or clipboard contents, light and dark if possible, Retina PNG (or WebP), under about 300 KB each. Put web images in `site/img/`; the relay serves every file in `site/` from startup, so no other change is needed.

| File | Shot |
|---|---|
| `hero-mac.png` | Mac menu bar dropdown with two paired devices, battery shown |
| `arrange-devices.png` | Settings → Universal Control → Arrange Devices… with a phone and tablet placed |
| `mirroring.png` | The borderless mirroring window with the phone's home screen |
| `notifications.png` | A mirrored notification with the inline reply field |
| `pairing.png` | Pair New Device QR on Mac beside the Android scanner |
| `settings-mac.png` | Mac Settings with the per-feature switches |
| `settings-android.png` | Android Settings with the per-feature switches |
| `relay.png` | Settings → Relay |

Once the files exist, add them to `site/index.html` (a gallery under the hero) and to the README under **Features**.
