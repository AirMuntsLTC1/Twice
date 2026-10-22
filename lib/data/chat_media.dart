import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_media_cache.dart';

/// Resolves chat media by its STABLE storage path (never by signed URL).
///
/// Signed URLs change on every request, which is what made thumbnails go
/// blank/black each time the chat reloaded. Here a storage path always maps
/// to the same file on disk, so a bubble keeps showing the exact same pixels.
class ChatMediaStore {
  ChatMediaStore._();
  static final ChatMediaStore instance = ChatMediaStore._();

  static const bucket = 'chat-media';

  final Map<String, String> _local = {}; // storage path -> local file path
  final Map<String, Future<String?>> _jobs = {}; // in-flight downloads
  final Map<String, _Signed> _signed = {};
  final Map<String, Future<String?>> _signJobs = {};

  SupabaseClient get _db => Supabase.instance.client;

  /// Synchronous lookup: lets a bubble paint its image on the very first
  /// frame when it was already resolved earlier in this session.
  String? localSync(String storagePath) {
    return _local[storagePath];
  }

  /// Returns a local file path for an image, downloading it once if needed.
  Future<String?> local(String storagePath) {
    if (storagePath.isEmpty) return Future<String?>.value(null);
    final known = _local[storagePath];
    if (known != null) return Future<String?>.value(known);
    return _jobs.putIfAbsent(storagePath, () async {
      try {
        var uri = await OfflineMediaCache.instance.existingUri(
          bucket,
          storagePath,
        );
        if (uri == null) {
          for (var attempt = 0; attempt < 3 && uri == null; attempt++) {
            if (attempt > 0) {
              await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
            }
            final url = await signedUrl(storagePath, force: attempt > 0);
            if (url == null) continue;
            uri = await OfflineMediaCache.instance.cacheFromUrl(
              bucket: bucket,
              objectPath: storagePath,
              signedUrl: url,
              isVideo: false,
              maxBytesOverride: 48 * 1024 * 1024,
            );
          }
        }
        if (uri == null) return null;
        final file = File.fromUri(Uri.parse(uri)).path;
        _local[storagePath] = file;
        return file;
      } catch (_) {
        return null;
      } finally {
        unawaited(Future<void>.microtask(() => _jobs.remove(storagePath)));
      }
    });
  }

  /// Signed URL that stays identical for ~50 minutes, so widgets keyed on it
  /// (video posters) do not restart on every rebuild.
  Future<String?> signedUrl(String storagePath, {bool force = false}) {
    if (storagePath.isEmpty) return Future<String?>.value(null);
    final cached = _signed[storagePath];
    if (!force && cached != null && cached.expires.isAfter(DateTime.now())) {
      return Future<String?>.value(cached.url);
    }
    return _signJobs.putIfAbsent(storagePath, () async {
      try {
        final url = await _db.storage
            .from(bucket)
            .createSignedUrl(storagePath, 3600)
            .timeout(const Duration(seconds: 15));
        if (!url.contains('token=')) return null;
        _signed[storagePath] = _Signed(
          url,
          DateTime.now().add(const Duration(minutes: 50)),
        );
        return url;
      } catch (_) {
        return null;
      } finally {
        unawaited(Future<void>.microtask(() => _signJobs.remove(storagePath)));
      }
    });
  }

  /// After sending media: remember the local file for this storage path and
  /// copy it into the persistent cache in the background.
  void registerSent(String storagePath, File source) {
    if (storagePath.isEmpty) return;
    _local[storagePath] = source.path;
    unawaited(
      OfflineMediaCache.instance
          .storeFile(bucket: bucket, objectPath: storagePath, source: source)
          .then((uri) {
        if (uri != null) {
          _local[storagePath] = File.fromUri(Uri.parse(uri)).path;
        }
      }),
    );
  }

  /// Drops a corrupt cached file so the next resolve downloads it again.
  Future<void> forget(String storagePath) async {
    _local.remove(storagePath);
    await OfflineMediaCache.instance.remove(bucket, storagePath);
  }

  /// Warm the cache for media that just arrived (no UI involved).
  void prefetch(String storagePath) {
    if (storagePath.isEmpty || _local.containsKey(storagePath)) return;
    unawaited(local(storagePath));
  }
}

class _Signed {
  _Signed(this.url, this.expires);
  final String url;
  final DateTime expires;
}
