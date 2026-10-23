import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Dart binding for the pure-C EXIF orientation helper added to
/// android/app/src/main/cpp/twice_native.cpp as
/// `twice_native_exif_orientation(const uint8_t*, int64_t)`.
///
/// Returns 1..8 for a valid EXIF orientation tag, 0 if absent, and 1
/// (normal) on any error or when the native library is unavailable.
/// This is used to pre-rotate a photo before it is uploaded or rendered
/// full-screen, so sideways phone photos stop appearing rotated.
///
/// The native side is pure C, allocation-free, and does not alter any
/// existing exported symbol. It is optional: the Dart fallback below
/// returns 1 (no rotation) when the library cannot be loaded.
class TwiceNativeMedia {
  TwiceNativeMedia._();

  static final TwiceNativeMedia instance = TwiceNativeMedia._();

  int Function(Pointer<Uint8>, int)? _exif;

  bool get available => _exif != null;

  void _ensureLoaded() {
    if (_exif != null) return;
    if (!Platform.isAndroid) return;
    try {
      final lib = DynamicLibrary.open('libtwice_native.so');
      _exif = lib.lookupFunction<
          Int32 Function(Pointer<Uint8>, Int64),
          int Function(Pointer<Uint8>, int)>(
        'twice_native_exif_orientation',
      );
    } catch (_) {
      _exif = null;
    }
  }

  /// Returns the EXIF orientation (1..8), or 1 when no hint is available.
  ///
  /// The returned value follows the EXIF spec:
  /// 1 = normal, 2 = flip H, 3 = rotate 180, 4 = flip V,
  /// 5 = transpose, 6 = rotate 90 CW, 7 = transverse, 8 = rotate 270 CW.
  int orientationOf(Uint8List bytes) {
    if (bytes.isEmpty) return 1;
    _ensureLoaded();
    final fn = _exif;
    if (fn == null) return 1;
    final ptr = malloc.allocate<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      final value = fn(ptr, bytes.length);
      if (value < 1 || value > 8) return 1;
      return value;
    } catch (_) {
      return 1;
    } finally {
      malloc.free(ptr);
    }
  }
}
