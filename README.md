# craft_driver CI test

Proves that Flutter apps can be driven via VM Service `evaluate()` on CI — no app-side setup needed.

## What this tests

- Launch a Flutter app with `flutter run --machine`
- Connect via VM Service
- Find widgets by text, type, tooltip
- Tap buttons, type into text fields, scroll lists
- Assert UI state via evaluate()
- All headless on CI (xvfb on Linux, native on macOS)

## Run locally

```bash
cd driver && dart pub get
dart run bin/ci_test.dart ../app
```

## CI

GitHub Actions runs on both macOS and Linux (headless via xvfb).
