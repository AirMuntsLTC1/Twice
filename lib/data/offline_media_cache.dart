import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Best-effort persistent cache for media already visible in the signed-in feed.
/// The database stores metadata; this cache stores media bytes for offline display.
class OfflineMediaCache {
  OfflineMediaCache._();
  static final OfflineMediaCache instance = OfflineMediaCache._();

  Future<Directory> _directory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'twice_media_cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _fileName(String bucket, String objectPath) {
    final encoded = base64Url
        .encode(utf8.encode('$bucket:$objectPath'))
        .replaceAll('=', '');
    final ext = p.extension(objectPath.split('?').first);
    return '${encoded.substring(0, encoded.length > 150 ? 150 : encoded.length)}'
        '${ext.isEmpty ? '.media' : ext}';
  }

  Future<String?> existingUri(String bucket, String objectPath) async {
    try {
      final file = File(p.join(
        (await _directory()).path,
        _fileName(bucket, objectPath),
      ));
      if (await file.exists() && await file.length() > 0) {
        return file.uri.toString();
      }
    } catch (_) {}
    return null;
  }

  /// Copies a local file (for example a photo you just sent) into the cache
  /// under the same key the downloader would use, so the chat never has to
  /// download its own media again.
  Future<String?> storeFile({
    required String bucket,
    required String objectPath,
    required File source,
  }) async {
    try {
      final existing = await existingUri(bucket, objectPath);
      if (existing != null) return existing;
      if (!await source.exists()) return null;
      final dir = await _directory();
      final target = File(p.join(dir.path, _fileName(bucket, objectPath)));
      final partial = File('${target.path}.part');
      await source.copy(partial.path);
      await partial.rename(target.path);
      return target.uri.toString();
    } catch (_) {
      return null;
    }
  }

  /// Removes a cached object (used when a cached file turns out to be corrupt).
  Future<void> remove(String bucket, String objectPath) async {
    try {
      final file = File(p.join(
        (await _directory()).path,
        _fileName(bucket, objectPath),
      ));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Returns a file:// URI only after a complete download has been committed.
  /// Large items are skipped rather than exhausting memory or disk.
  Future<String?> cacheFromUrl({
    required String bucket,
    required String objectPath,
    required String signedUrl,
    required bool isVideo,
    int? maxBytesOverride,
  }) async {
    final existing = await existingUri(bucket, objectPath);
    if (existing != null) return existing;
    final maxBytes =
        maxBytesOverride ?? (isVideo ? 80 * 1024 * 1024 : 18 * 1024 * 1024);
    final dir = await _directory();
    final target = File(p.join(dir.path, _fileName(bucket, objectPath)));
    final partial = File('${target.path}.part');
    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(signedUrl));
      final response = await client.send(request).timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode != 200) return null;
      if (response.contentLength != null &&
          response.contentLength! > maxBytes) {
        return null;
      }

      final output = partial.openWrite();
      sink = output;
      var written = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 25),
      )) {
        written += chunk.length;
        if (written > maxBytes) {
          await output.flush();
          await output.close();
          sink = null;
          await partial.delete().catchError((_) => partial);
          return null;
        }
        output.add(chunk);
      }
      await output.flush();
      await output.close();
      sink = null;
      if (written == 0) {
        await partial.delete().catchError((_) => partial);
        return null;
      }
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      return target.uri.toString();
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return null;
    } finally {
      client.close();
    }
  }
}
