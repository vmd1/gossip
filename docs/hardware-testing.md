# Hardware testing

What needs real devices, and what has already been checked without them. Tick things off here as they are tested.

## Already checked without hardware

- Unit tests: Android (`./gradlew :app:testDebugUnitTest`) and Mac (`xcodebuild test`) cover the screen-mirroring state machine, the locked-phone refusal, screen-off timeout handling, one-time-code detection (shared cases in `schema/otp-cases.json`), richer notification payloads, the clipboard image history and `media.volume`.
- Android emulator (API 34): the app launches, and the sync service restarts after an app update (`MY_PACKAGE_REPLACED`).

## Needs a phone with Shizuku

- [ ] **Locked phone:** lock the phone with a PIN, open an app window from the Mac. Expect "Unlock it to open its apps". Open a window, then lock the phone: the window closes. Turn on Settings → Features → Mirror apps while locked: both stop applying.
- [ ] **Screen-off mirroring** (on at least two OEMs): the panel goes dark, the mirror keeps its frame rate, and ending the mirror (or killing the app) puts `screen_off_timeout` back. Start a second mirror while one is live: the first ending must not light the panel or reset the timeout.
- [ ] **Keyboard and rotation in the Android viewer:** type, Backspace and Enter reach the mirrored device; rotating the source rotates the viewer and the session survives.

## Needs a Mac and a phone

- [ ] **Login codes:** an SMS with "Your code is 123456" mirrored to the Mac shows a Copy code button, and the same on a second Android device.
- [ ] **Richer notifications:** a messaging app with a contact photo, a notification with a picture, a download progress notification (the Mac shows "Progress: N%", Android shows a bar), buttons (Archive, Mark as read) pressed from the Mac, a suggested reply tapped.
- [ ] **`media.volume`:** send a level from the Mac and check the phone's media volume.
- [ ] **Clipboard images:** copy an image on each device and check the history shows it, and copying it back works.

## Needs more hardware

- [ ] Multi-display mirroring on a Mac with two or more monitors.
- [ ] Android → Android mirroring between two real devices.
- [ ] Relay keepalive and battery over a day on a phone off the home network.
