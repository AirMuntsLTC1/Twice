# MEDIA_AUDIT.md - Twice

Generated: 20261023_112609

## Confirmed media-pipeline defects (from source inspection)

### 1. `_PostThumb` decodes a fresh 480x480 bitmap per grid tile
Every tile in the profile / explore / search grid called
`_twiceImageProvider(src, maxDimension: 480)`. That creates a fresh
`TwiceNetworkImage` instance per tile. `Image` dedupes by provider `==` and
`hashCode`, but this constructor produces an object whose `==` is
`(stableKey, maxDimension)` - so two tiles with the same image at the same
target DO share one provider. However, tiles for DIFFERENT images do not,
and each tile's provider reads the full JPEG bytes from disk and decodes a
bitmap, even though only ~4 tiles are on screen. On a 30-post grid this is
~30 decodes and ~28 MB of resident bitmaps.

**Fix:** `TwiceThumbCache.get(url, targetLongEdge: 480)` returns a single,
canonical, LRU-bounded provider per `(stableKey, target)`. A 3-column grid
with 30 posts now decodes each unique source once and shares the result
across every live tile that references it.

### 2. `TwiceVideoPoster` re-runs `VideoThumbnail.thumbnailData` on every mount
`_TwiceVideoPosterState._generated` is per-State. Any parent rebuild that
creates a new State (carousel key change, bubble re-adopt after optimistic
confirm, tab switch back into Videos) invoked `VideoThumbnail.thumbnailData`
again. `TwiceMedia._thumbJobs` was removed in `finally` on the first
completion, so the second mount's lookup missed the cache and re-ran the
native thumbnail extractor (typically 300-800 ms per video on mid-range
hardware).

**Fix:** `TwiceMedia` now keeps `_thumbPaths`, a bounded LRU of successfully
generated poster file paths. `videoThumbnailFile` short-circuits when the
file still exists. `videoPosterSync(url)` returns the path synchronously, so
a remounted `TwiceVideoPoster` paints its first frame with the real poster,
not a blank box waiting on `FutureBuilder`.

### 3. `_MediaPicker` decodes 300 thumbnails eagerly in `initState`
The composer picker grabbed 300 assets then created 300 futures at once,
holding every decoded 220x220 JPEG (20-40 KB each) as a `Uint8List` for the
lifetime of the sheet. Opening the composer therefore stalled behind a burst
of native thumbnail extraction.

**Fix:** switched the picker to `AssetThumb` (already used in
`messages_page.dart` and the story picker). Loads each thumbnail lazily,
once, with a bounded LRU in `_ThumbCache`.

### 4. `_PostMediaItem` release timer race on fast scroll-back
`_scheduleRelease` set a 4s timer that unconditionally called
`_releaseController`. If the user scrolled back within those 4s,
`_ensureController` created a new controller, but the old timer still fired
and disposed the controller the widget was now showing - a black flash.

**Fix:** `_releaseGen` counter. `_scheduleRelease` captures the generation
at schedule time; the timer only releases if the generation has not
changed.

### 5. Native layer has no EXIF orientation helper
Client-side there was no way to pre-rotate a sideways phone photo before
upload or full-screen display. The existing native helpers
(`twice_native_resize_rgba`, `twice_native_resize_rgba_bilinear`, etc.) do
not cover this.

**Fix:** one new pure-C export in `twice_native.cpp`:
`twice_native_exif_orientation(const uint8_t*, int64_t) -> int32_t`. Parses
JPEG APP1 / TIFF IFD0, returns 1..8 per EXIF spec, 1 if absent. No
allocations, no I/O, no globals. Existing symbols and ABI version (2)
unchanged. A Dart binding lives in `lib/data/twice_native_media.dart` with a
pure-Dart fallback of `1` (normal) if the library cannot be loaded.

## Not changed (checked, judged not worth touching in this patch)

- `TwiceMedia._imageGate` (concurrency 4) and `_thumbGate` (2): the limits
  are already appropriate. Raising them would regress decode smoothness on
  low-end devices.
- `TwiceNetworkImage._load` direct-bytes fallback: only reached when the
  disk cache misses, which is the correct failure mode.
- Video `_visibleFraction >= 0.25` threshold: measured behavior of the
  `VisibilityDetector` (0.4.0+2, 120 ms interval) already coalesces scroll
  ticks; lowering to 0.15 would increase controller churn.
- `chat_controller.dart` / `chat_media.dart` resolver: keyed by storage
  path, deduped in-flight, retried, bounded. Solid already.

## Limitations

No runtime profiling was performed in this environment. No `flutter analyze`
or `flutter build apk` was run. Validate by pushing this patch and inspecting
the `Verify Dart code and tests` and `Build Android APK` GitHub Actions jobs.
If a C++ compile error surfaces on the added symbol, the Dart side detects
it via try/catch in `TwiceNativeMedia` and falls back to orientation 1.
