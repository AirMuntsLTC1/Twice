// Facebook-style media engine for Twice.
//
// Fixes: feed images / avatars / video posters turning blank when scrolling
// back, because (1) NetworkImage was keyed by the *signed URL* (it changes on
// every refresh) and had no disk cache, and (2) cards were rebuilt from zero.
//
// What this does:
//  * TwiceNetworkImage: ImageProvider keyed by stable bucket/object path,
//    persistent disk cache, de-duplicated downloads, retry, downscaled decode.
//  * Bigger in-memory image cache so scrolled-away images return instantly.
//  * TwiceVideoPoster: always shows a thumbnail (uploaded one, or one generated
//    from the video and cached on disk).
//  * Disk cache trimming so the cache never grows forever.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'offline_media_cache.dart';

class _Gate {
  _Gate(this.limit);
  final int limit;
  int _running = 0;
  final List<Completer<void>> _waiters = [];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= limit) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }
}

class TwiceMedia {
  TwiceMedia._();

  static final _imageGate = _Gate(4);
  static final _thumbGate = _Gate(2);
  static final _videoGate = _Gate(1);
  static final Map<String, Future<File?>> _imageJobs = {};
  static final Map<String, Future<String?>> _thumbJobs = {};
  static final Map<String, Future<String?>> _videoJobs = {};
  static Directory? _thumbDirectory;

  /// Debug-only counters. Zero in release builds because nothing reads them.
  static int debugHits = 0;
  static int debugMisses = 0;
  static void resetDebugCounters() { debugHits = 0; debugMisses = 0; }

  /// Call once at startup.
  static void configure() {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = 300 * 1024 * 1024;
    cache.maximumSize = 1500;
    VisibilityDetectorController.instance.updateInterval =
        const Duration(milliseconds: 120);
  }

  /// Stable identity of a media URL (signed URL tokens are ignored).
  static ({String bucket, String path}) identify(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      final segs = uri.pathSegments;
      final i = segs.indexOf('object');
      if (i >= 0 && i + 3 < segs.length) {
        return (bucket: segs[i + 2], path: segs.sublist(i + 3).join('/'));
      }
    }
    return (bucket: '_web', path: url.split('?').first);
  }

  static String stableKey(String url) {
    final id = identify(url);
    return '${id.bucket}:${id.path}';
  }

  static String _hash(String input) {
    // Two independent 32-bit FNV-1a hashes (web/native safe, collision-resistant).
    var a = 0x811c9dc5;
    var b = 0x01000193;
    for (final unit in input.codeUnits) {
      a = ((a ^ unit) * 0x01000193) & 0xFFFFFFFF;
      b = ((b ^ unit) * 0x85ebca6b) & 0xFFFFFFFF;
    }
    return '${a.toRadixString(16)}${b.toRadixString(16)}${input.length}';
  }

  static Future<String?> cachedFileUri(String url) async {
    final id = identify(url);
    return OfflineMediaCache.instance.existingUri(id.bucket, id.path);
  }

  /// Returns the on-disk file for an image URL, downloading it once if needed.
  static Future<File?> imageFile(String url) {
    final key = stableKey(url);
    return _imageJobs.putIfAbsent(key, () async {
      try {
        final id = identify(url);
        var uri = await OfflineMediaCache.instance.existingUri(
          id.bucket,
          id.path,
        );
        if (uri != null) {
          debugHits++;
        } else {
          debugMisses++;
        }
        if (uri == null) {
          for (var attempt = 0; attempt < 3 && uri == null; attempt++) {
            if (attempt > 0) {
              await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
            }
            uri = await _imageGate.run(
              () => OfflineMediaCache.instance.cacheFromUrl(
                bucket: id.bucket,
                objectPath: id.path,
                signedUrl: url,
                isVideo: false,
              ),
            );
          }
        }
        return uri == null ? null : File.fromUri(Uri.parse(uri));
      } catch (_) {
        return null;
      } finally {
        // Keep successful results out of the map; the disk is the cache.
        unawaited(Future<void>.microtask(() => _imageJobs.remove(key)));
      }
    });
  }

  /// Raw bytes for images too large for the disk cache limit (direct fetch).
  static Future<Uint8List?> _directBytes(String url) async {
    if (!url.startsWith('http')) return null;
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> _thumbDir() async {
    final cached = _thumbDirectory;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'twice_media_cache', 'thumbs'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _thumbDirectory = dir;
  }

  /// A JPEG poster generated from the video itself (cached on disk).
  static Future<String?> videoThumbnailFile(String videoUrl) {
    final key = stableKey(videoUrl);
    return _thumbJobs.putIfAbsent(key, () async {
      try {
        final dir = await _thumbDir();
        final out = File(p.join(dir.path, '${_hash(key)}.jpg'));
        if (await out.exists() && await out.length() > 0) return out.path;

        var source = videoUrl;
        if (videoUrl.startsWith('file://')) {
          source = File.fromUri(Uri.parse(videoUrl)).path;
        } else {
          final local = await cachedFileUri(videoUrl);
          if (local != null) source = File.fromUri(Uri.parse(local)).path;
        }
        final bytes = await _thumbGate.run(
          () => VideoThumbnail.thumbnailData(
            video: source,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 720,
            quality: 75,
            timeMs: 300,
          ).timeout(const Duration(seconds: 25)),
        );
        if (bytes == null || bytes.isEmpty) {
          _thumbJobs.remove(key);
          return null;
        }
        await out.writeAsBytes(bytes, flush: true);
        return out.path;
      } catch (_) {
        _thumbJobs.remove(key);
        return null;
      }
    });
  }

  /// Background-save a video you are watching so replays are instant/offline.
  static Future<String?> cacheVideo(String videoUrl) {
    if (!videoUrl.startsWith('http')) return Future.value(null);
    final key = stableKey(videoUrl);
    return _videoJobs.putIfAbsent(key, () async {
      try {
        final id = identify(videoUrl);
        return await _videoGate.run(
          () => OfflineMediaCache.instance.cacheFromUrl(
            bucket: id.bucket,
            objectPath: id.path,
            signedUrl: videoUrl,
            isVideo: true,
          ),
        );
      } catch (_) {
        return null;
      } finally {
        unawaited(Future<void>.microtask(() => _videoJobs.remove(key)));
      }
    });
  }

  /// Runs the disk-cache trim on a background microtask so it does not jank
  /// the first frame. Single pass over the directory, one stat per file.
  static void scheduleTrimDiskCache({int maxBytes = 600 * 1024 * 1024}) {
    Future<void>.delayed(const Duration(seconds: 8), () {
      trimDiskCache(maxBytes: maxBytes).catchError((Object _) {});
    });
  }

  /// Keeps the on-disk cache under [maxBytes] by deleting the oldest files.
  static Future<void> trimDiskCache({int maxBytes = 600 * 1024 * 1024}) async {
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'twice_media_cache'));
      if (!await root.exists()) return;
      final files = <File>[];
      var total = 0;
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File) {
          files.add(e);
          total += await e.length();
        }
      }
      if (total <= maxBytes) return;
      final stats = <File, DateTime>{};
      for (final f in files) {
        stats[f] = (await f.stat()).modified;
      }
      files.sort((a, b) => stats[a]!.compareTo(stats[b]!));
      for (final f in files) {
        if (total <= maxBytes * 0.8) break;
        final size = await f.length();
        try {
          await f.delete();
          total -= size;
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// ImageProvider with a stable identity + disk cache (Facebook-style).
@immutable
class TwiceNetworkImage extends ImageProvider<TwiceNetworkImage> {
  const TwiceNetworkImage(this.url, {this.maxDimension = 1080});

  final String url;
  final int maxDimension;

  String get _stable => TwiceMedia.stableKey(url);

  @override
  Future<TwiceNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<TwiceNetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(
    TwiceNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      debugLabel: key._stable,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
      ],
    );
  }

  Future<ui.Codec> _load(
    TwiceNetworkImage key,
    ImageDecoderCallback decode,
  ) async {
    Uint8List? bytes;
    final file = await TwiceMedia.imageFile(key.url);
    if (file != null) {
      bytes = await file.readAsBytes();
    } else {
      bytes = await TwiceMedia._directBytes(key.url);
    }
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Twice image unavailable: ${key._stable}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final limit = key.maxDimension;
    return decode(
      buffer,
      getTargetSize: (int w, int h) {
        final longest = math.max(w, h);
        if (longest <= limit) return ui.TargetImageSize(width: w, height: h);
        final s = limit / longest;
        return ui.TargetImageSize(
          width: math.max(1, (w * s).round()),
          height: math.max(1, (h * s).round()),
        );
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TwiceNetworkImage &&
      other._stable == _stable &&
      other.maxDimension == maxDimension;

  @override
  int get hashCode => Object.hash(_stable, maxDimension);

  @override
  String toString() => 'TwiceNetworkImage($_stable)';
}

/// Always-visible video poster: uploaded thumbnail, else generated frame.
class TwiceVideoPoster extends StatefulWidget {
  const TwiceVideoPoster({
    super.key,
    required this.videoUrl,
    required this.thumbnailUrl,
    required this.imageProviderFor,
    this.fit = BoxFit.contain,
    this.showPlayIcon = true,
  });

  final String videoUrl;
  final String thumbnailUrl;
  final ImageProvider<Object> Function(String source) imageProviderFor;
  final BoxFit fit;
  final bool showPlayIcon;

  @override
  State<TwiceVideoPoster> createState() => _TwiceVideoPosterState();
}

class _TwiceVideoPosterState extends State<TwiceVideoPoster> {
  Future<String?>? _generated;

  Future<String?> _generate() =>
      _generated ??= widget.videoUrl.isEmpty
      ? Future<String?>.value(null)
      : TwiceMedia.videoThumbnailFile(widget.videoUrl);

  Widget _image(ImageProvider<Object> provider, {Widget? onError}) => Image(
    image: provider,
    fit: widget.fit,
    width: double.infinity,
    height: double.infinity,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => onError ?? const SizedBox.shrink(),
  );

  Widget _generatedPoster() => FutureBuilder<String?>(
    future: _generate(),
    builder: (context, snap) {
      final path = snap.data;
      if (path == null) return const SizedBox.shrink();
      return _image(
        ResizeImage.resizeIfNeeded(1080, null, FileImage(File(path))),
      );
    },
  );

  @override
  void didUpdateWidget(covariant TwiceVideoPoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (TwiceMedia.stableKey(oldWidget.videoUrl) !=
        TwiceMedia.stableKey(widget.videoUrl)) {
      _generated = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumb = widget.thumbnailUrl.trim();
    return ColoredBox(
      color: const Color(0xFF101114),
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          if (thumb.isNotEmpty)
            _image(
              widget.imageProviderFor(thumb),
              onError: _generatedPoster(),
            )
          else
            _generatedPoster(),
          if (widget.showPlayIcon)
            const Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0x73000000),
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
