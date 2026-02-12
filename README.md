# Eero Control

[![CI](https://github.com/davelindo/eero-menu-bar/actions/workflows/ci.yml/badge.svg)](https://github.com/davelindo/eero-menu-bar/actions/workflows/ci.yml)

Native macOS menu bar app for monitoring and controlling an eero network via eero's cloud API, with offline-local diagnostics and caching.

> Unofficial project: not affiliated with eero or Amazon. The APIs used here are undocumented and may change.

## What The Project Does

Eero Control is a SwiftUI macOS app that:

- Signs into your eero account (login + verification code) and stores a session token in Keychain.
- Polls the eero cloud API for account/network state and exposes common controls.
- Provides offline-local diagnostics (gateway/DNS/route probes) and a last-known snapshot when the cloud is unreachable.

## Why It's Useful

- Menu bar throughput indicator (PingBar-style `↓`/`↑`) plus a quick popover for common actions.
- Full control window with dedicated sections:
  - Dashboard (dense "HUD" style overview)
  - Clients (Primary/Guest LAN split, search, pause/resume)
  - Profiles (pause/resume, content filters, blocked apps)
  - Network (feature toggles, reboot, telemetry)
  - Offline (local probes, queued action replay)
  - Settings (polling, gateway, auth)
- Offline resilience:
  - Local probes and health labels designed to work even when the internet is down.
  - Cached last-known account snapshot and queued safe actions with replay.

## Getting Started

### Requirements

- macOS 13+
- Xcode 15+ (Swift 5.9)

Optional tooling:

- `xcodegen` (only needed if you regenerate the Xcode project or use the release build script)
- `swift-format` (formatting; CI uses this)
- `gitleaks` (secret scanning; CI uses this via GitHub Action)

### Build And Run (Xcode)

1. Clone the repo.
2. Open `EeroControl.xcodeproj` in Xcode.
3. Select the `EeroControl` scheme and Run.

### Build And Run (CLI)

```bash
xcodebuild \
  -project EeroControl.xcodeproj \
  -scheme EeroControl \
  -configuration Debug \
  -destination "platform=macOS" \
  build
```

### Build A Release .app Bundle

The helper script regenerates the Xcode project from `project.yml` (XcodeGen) and copies the resulting `.app` into `build/`.

```bash
brew install xcodegen
./scripts/build_release.sh
open build/EeroControl.app
```

### First-Time Usage

1. Launch the app.
2. In **Settings**, enter your login (email or phone number) and complete verification.
3. Select a network from the **Network** picker.

### Telemetry Note (Important)

The app can display two different notions of "throughput":

- **Network telemetry**: when the cloud API provides realtime throughput for the selected network.
- **Local interface** fallback: your Mac's current network interface counters (what this machine is doing), not whole-home traffic.

## Documentation

- API behavior and routes used by this app: `docs/eero-api.md`
- Discovered endpoint inventories used for coverage tracking:
  - `docs/eero-api-discovered-endpoints.tsv`
  - `docs/eero-api-discovered-path-strings.txt`

## Where Users Can Get Help

- GitHub Issues: https://github.com/davelindo/eero-menu-bar/issues
- API mapping and app behavior notes: `docs/eero-api.md`

## Who Maintains And Contributes

Maintainer: Dave Lindon (GitHub: `@davelindo`)

Contributions are welcome:

- Keep changes focused and include tests where it makes sense.
- Run formatting and tests locally (see below) before opening a PR.
- Never commit tokens, cookies, or account identifiers. CI runs a secret scan.

Contribution guidelines: `docs/CONTRIBUTING.md`

### Development Commands

Format (lint):

```bash
brew install swift-format
swift-format lint --recursive Sources Tests
```

Test:

```bash
xcodebuild \
  -project EeroControl.xcodeproj \
  -scheme EeroControl \
  -configuration Debug \
  -destination "platform=macOS" \
  test
```

### Project Layout

- App code: `Sources/EeroControl`
- Resources (Info.plist, entitlements, assets): `Resources`
- Unit tests: `Tests`
- Docs (API notes and endpoint inventories): `docs`
- Release build script: `scripts/build_release.sh`
- Local reference repos / artifacts (ignored): `third-party/`
