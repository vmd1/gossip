# Design system

Established during the onboarding/polish handoff's Phase 6
(`HANDOFF_ONBOARDING_AND_POLISH.md`) — this repo had no design-system doc before this, and every
screen picked colors/spacing ad hoc (in practice: neither app set anything, so Android rendered
Material3's default un-seeded purple scheme and Mac rendered whatever the user's system accent
color happened to be). This doc is intentionally small: Gossip is a personal-use background
utility, not a flagship consumer app, so the goal is *consistency and native feel*, not a custom
visual identity competing with the OS.

## Color

**Accent**: system blue (`#0A84FF`, Apple's system blue — chosen as the shared reference point
since it's also SwiftUI's default accent color on macOS). Used as the Compose Material3 seed
color on Android (`ConnectTheme`, `android/app/src/main/kotlin/dev/vmd1/gossip/ui/theme/Theme.kt`) so
both platforms present the same default accent hue instead of Android showing Material3's
unrelated default purple.

- **Mac**: deliberately does **not** hardcode this — SwiftUI's default `.tint`/`accentColor`
  already follows the user's own System Settings → Appearance → Accent Color choice, which is
  more native-feeling than overriding it, and defaults to the same system blue for any user who
  hasn't changed it. Forcing a fixed brand color here would work *against* platform convention for
  users who picked a different accent, for no real benefit to a personal utility app.
- **Android**: Compose has no equivalent "follow the OS accent" mechanism as of this app's
  `compileSdk` (dynamic color / Material You reads the *wallpaper*, not a user-chosen accent, and
  behaves inconsistently across OEMs) — so a fixed seed color is the more predictable choice here,
  and matching Mac's common-case default keeps the two platforms visually aligned without adding
  per-user preference plumbing neither platform's UI currently has anywhere else.
- **Status/warning colors** (e.g. the screen-mirroring-active banner, permission-missing warnings)
  use Material3's semantic roles (`errorContainer`/`onErrorContainer` on Android,
  `.foregroundStyle(.red)` on Mac) rather than new custom colors — both already had this
  convention before this doc; it's just being named here so it doesn't drift.

## Spacing

Both platforms already converged independently on the same informal scale without a shared doc —
naming it here so it stays that way rather than drifting per-screen:

- **4pt/dp** — tight spacing within a single control (e.g. between an icon and its label)
- **8pt/dp** — between closely-related elements (a row's internal `HStack`/`Row` spacing)
- **12–16pt/dp** — between distinct rows/sections within one screen
- **24pt/dp** — outer screen padding

Compose screens should use `Arrangement.spacedBy(...)` with these values rather than manual
per-`Spacer` padding; SwiftUI screens should use `VStack(spacing:)`/`.padding()` the same way.

## Motion

Minimal and functional, not decorative — this app's UI is mostly a menu-bar dropdown and a couple
of settings screens, not a place that benefits from flourish:

- **State transitions that change meaning** (e.g. the multi-step onboarding flow advancing, a
  permission's granted/not-granted row appearing or disappearing) should use a short, simple
  cross-fade or slide — Compose's `AnimatedContent`/`AnimatedVisibility` with their default
  durations, SwiftUI's implicit `.animation(.default, value:)` — rather than an instant cut, so
  the UI reads as *responding* to what the user just did rather than just re-rendering.
- **Nothing should animate on a timer or loop** — only in direct response to a state change a user
  action (or a real underlying event, like a device connecting) caused.
- Do not add custom easing curves, spring physics tuning, or multi-stage choreographed animations
  — both platforms' default system animation curves are already tuned for this and match the rest
  of each OS's own UI.

## Iconography

SF Symbols on Mac (already the convention — see `DeviceType.symbolName` in
`mac/Gossip/Crypto/TrustedDevicesStore.swift`), Material Symbols (`androidx.compose.material.icons`)
on Android — no custom icon assets. This was already the de facto convention; recorded here so a
future screen doesn't introduce a one-off custom asset instead.

## What this doc deliberately does not cover

Dark mode: both platforms already get it for free (SwiftUI follows system appearance
automatically; Android's Material3 `ConnectTheme` defines both a light and dark `ColorScheme`, see
below) — there is no separate "dark mode design" decision to make beyond making sure the color
roles above resolve sensibly in both, which Material3's semantic color roles and SwiftUI's system
colors already handle.
