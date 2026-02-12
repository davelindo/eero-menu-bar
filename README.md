# Eero Control

Native macOS eero control app with a menu bar popover, full control window, and offline-local diagnostics.

## Current implementation

- Menu bar item with popover quick controls.
- PingBar-style menu bar throughput display (`↓`/`↑`) driven by realtime local interface counters with cloud speed fallback.
- Full app window with tabs:
  - Dashboard
  - Clients
  - Profiles
  - Network
  - Offline
  - Settings
- eero auth flow:
  - login request
  - verification code
  - keychain token restore/refresh
- Cloud polling with adaptive foreground/background intervals.
- Extended controls:
  - guest network
  - client pause/resume
  - profile pause/resume
  - profile content filters
  - profile blocked apps
  - network feature toggles (where exposed)
  - device status light and reboot
  - network reboot, speed test, and burst reporter trigger
- Extended cloud data coverage:
  - explicit `guestnetwork` resource fetch
  - routing (reservations/forwards/pinholes)
  - diagnostics, support, updates, speed test summaries
  - blacklist, ac-compat, insights/ouicheck probes
- Offline mode:
  - gateway/DNS/NTP/route local probes
  - NTP probe treated as optional so LAN health is not marked failed when UDP/123 is closed
  - cached last-known snapshot
  - queued safe actions with replay

## Build

```bash
xcodegen generate
xcodebuild -project EeroControl.xcodeproj -scheme EeroControl -configuration Debug -destination "platform=macOS" build
```

Or use the release helper:

```bash
./scripts/build_release.sh
```
