# Contributing to Eero Control

Thanks for contributing. This repo is intentionally kept small and pragmatic: keep PRs tight, tested, and easy to review.

## Development Setup

Requirements:

- macOS 13+
- Xcode 15+ (Swift 5.9)

Optional tooling used by CI:

- `swift-format` for formatting/linting

```bash
brew install swift-format
swift-format lint --recursive Sources Tests
```

## Building And Testing

Build:

```bash
xcodebuild \
  -project EeroControl.xcodeproj \
  -scheme EeroControl \
  -configuration Debug \
  -destination "platform=macOS" \
  build
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

## Project Generation (XcodeGen)

`project.yml` is the XcodeGen spec used by the release build script. If you add files or need to adjust build settings, regenerate the project:

```bash
brew install xcodegen
xcodegen generate --spec project.yml
```

## PR Guidelines

- Prefer adding capabilities by extending the route catalogs and `docs/eero-api.md` rather than hard-coding new endpoints in random places.
- Avoid UI churn without screenshots. For UX changes, include before/after screenshots or a short screen recording.
- Keep privacy in mind:
  - Do not commit real tokens/cookies.
  - Avoid uploading logs that include account IDs or device MAC addresses.
- Keep offline mode working. Local probes should degrade gracefully and never block the UI thread.

