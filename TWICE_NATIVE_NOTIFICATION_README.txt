Twice native notification scoring update

Files:
- lib/data/notification_service.dart
- lib/data/twice_native_notifications.dart
- android/app/src/main/cpp/twice_native.cpp

The adapter uses C++ ABI v2 notification priority when available and
falls back to Dart scoring when the native library is unavailable.
It only orders queued in-app banners; Firebase delivery, Android system
notification display, payloads, and navigation routing remain in Dart.

Apply these files to the matching paths in the Twice project.
Do not include backups, credentials, or environment files.
