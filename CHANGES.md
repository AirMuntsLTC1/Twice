# CHANGES.md

## Modified
- `lib/data/twice_media.dart` - added `TwiceThumbCache` (LRU of stable
  providers), added `_thumbPaths` and `videoPosterSync`, rewrote
  `videoThumbnailFile` to persist successful posters, seeded
  `TwiceVideoPoster._generated` from the poster cache on init and on
  `didUpdateWidget`.
- `lib/main.dart` - `_PostThumb` uses `TwiceThumbCache.get(...)`;
  `_MediaPicker` uses `AssetThumb` (removed eager 300-thumbnail decode);
  `_PostMediaItem` gained `_releaseGen` guard around `_releaseController`.
- `android/app/src/main/cpp/twice_native.cpp` - appended
  `twice_native_exif_orientation(const uint8_t*, int64_t)` (pure C, no
  allocations, no I/O). ABI version unchanged.

## Added
- `lib/data/twice_native_media.dart` - FFI binding for the EXIF helper with
  a pure-Dart fallback.
- `MEDIA_AUDIT.md`, `CHANGES.md`, `VALIDATION.md` (this bundle).

## Not modified
- `pubspec.yaml`, `pubspec.lock`
- Any Gradle / AGP / Kotlin / NDK / SDK / Java version
- Any Supabase migration, policy, function, or edge function
- `android/app/src/main/kotlin/...` (no Kotlin changes)
- `lib/ads/*`, `lib/data/inbox_controller.dart` (already patched in
  commit `6cbd105`)
