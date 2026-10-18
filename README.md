# Twice

Twice is a Flutter social-media UI prototype with a C++ native core.

## Current scope

- Home feed with local demo posts
- Story strip and profile cards
- Local like/unlike interactions
- Explore search across demo content
- Create-post UI with in-memory demo publishing
- Profile and activity screens
- C++ library accessed through Dart FFI
- GitHub Actions workflow for an Android debug APK

## Backend

Supabase is intentionally not configured yet. No Supabase keys,
database tables, authentication, or remote storage are included.

## Build

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

The GitHub Actions workflow runs the checks and uploads `app-debug.apk`
as the `Twice-debug-APK` workflow artifact.
