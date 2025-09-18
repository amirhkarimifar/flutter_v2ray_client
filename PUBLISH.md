# Publish Guide (pub.dev)

Follow these steps to publish `flutter_v2ray_client` to pub.dev.

## Pre-publish checklist
- [ ] Verify `pubspec.yaml` metadata (name, version, homepage, repository, issue_tracker)
- [ ] Ensure LICENSE is present (MIT)
- [ ] Update `CHANGELOG.md` with the new version entry
- [ ] Ensure README includes usage examples and badges (optional)
- [ ] Run static checks
  - `flutter pub get`
  - `dart analyze`
  - `dart format --set-exit-if-changed .`
- [ ] Test example on Android device/emulator

## Publishing
- Authenticate with pub.dev if needed:
  - `dart pub token add https://pub.dev`
- Dry-run the publish:
  - `dart pub publish --dry-run`
- If all checks pass, publish:
  - `dart pub publish`

## Versioning
- Use semantic versioning: MAJOR.MINOR.PATCH
- Bump the version in `pubspec.yaml` and add the entry to `CHANGELOG.md`

## Notes
- iOS has no functional implementation; the podspec and class exist for API parity. Documented in README.
- Android minSdk 21, compileSdk 34 (update as needed).
