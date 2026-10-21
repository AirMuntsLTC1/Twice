import 'package:path/path.dart' as p;
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:photo_manager/photo_manager.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'local_cache.dart';
import 'offline_media_cache.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase data boundary for Twice. UI widgets should call this repository
/// rather than issuing database requests directly.
class SocialRepository {
  SocialRepository._();
  static final SocialRepository instance = SocialRepository._();
  SupabaseClient get _db => Supabase.instance.client;
  String get userId => _db.auth.currentUser!.id;
  LocalCache get _cache => LocalCache.instance;

  Future<List<Map<String, dynamic>>> cachedFeed() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    final value = await _cache.get(uid, 'feed');
    if (value is! List) return [];
    final posts =
        value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return _applyPendingToPosts(uid, posts);
  }

  Future<Map<String, dynamic>?> cachedMyProfile() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    final value = await _cache.get(uid, 'profile');
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<List<Map<String, dynamic>>> cachedStories() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    final value = await _cache.get(uid, 'stories');
    if (value is! List) return [];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Merges pending outbox mutations (likes, bookmarks, comments) into feed posts
  /// so local changes are never overwritten by stale network snapshots or cache reads.
  Future<List<Map<String, dynamic>>> _applyPendingToPosts(
    String uid,
    List<Map<String, dynamic>> posts,
  ) async {
    final pending = await _cache.pending(uid);
    if (pending.isEmpty) return posts;

    final byId = <String, Map<String, dynamic>>{
      for (final p in posts) (p['id'] ?? '').toString(): p,
    };

    for (final item in pending) {
      final op = item['operation'];
      final payload = item['payload'];
      if (payload is! Map) continue;

      final postId = payload['post_id']?.toString();
      if (postId == null || !byId.containsKey(postId)) continue;
      final post = byId[postId]!;

      if (op == 'set_like') {
        final liked = payload['liked'] == true;
        final likes = List<Map<String, dynamic>>.from(
          (post['post_likes'] as List? ?? const []).whereType<Map>().map(
            (row) => Map<String, dynamic>.from(row),
          ),
        );
        likes.removeWhere((row) => row['user_id']?.toString() == uid);
        if (liked) likes.add({'user_id': uid});
        post['post_likes'] = likes;
      } else if (op == 'set_saved') {
        final saved = payload['saved'] == true;
        final savedRows = List<Map<String, dynamic>>.from(
          (post['saved_posts'] as List? ?? const []).whereType<Map>().map(
            (row) => Map<String, dynamic>.from(row),
          ),
        );
        savedRows.removeWhere((row) => row['user_id']?.toString() == uid);
        if (saved) savedRows.add({'user_id': uid});
        post['saved_posts'] = savedRows;
      }
    }
    return posts;
  }

  Future<Map<String, dynamic>> _resolveProfileAvatar(
    Map<String, dynamic> row,
  ) async {
    final path = (row['avatar_url'] ?? '').toString().trim();
    row['avatar_object_path'] = path.startsWith('http') ? '' : path;
    if (path.isEmpty || path.startsWith('http')) return row;
    try {
      final local = await OfflineMediaCache.instance.existingUri(
        'post-media',
        path,
      );
      if (local != null) {
        row['avatar_url'] = local;
      } else {
        final signed = await _db.storage
            .from('post-media')
            .createSignedUrl(path, 3600);
        row['avatar_url'] = signed;
        unawaited(
          _warmAvatarCache(row, path, signed).catchError((Object _) {}),
        );
      }
    } catch (_) {
      // Keep the stored path if storage cannot resolve it.
    }
    return row;
  }

  // FBFIX: only download once. The next feed load finds the file through
  // OfflineMediaCache.existingUri(); rewriting the whole feed JSON per avatar
  // caused UI lag.
  Future<void> _warmAvatarCache(
    Map<String, dynamic> profile,
    String objectPath,
    String signedUrl,
  ) async {
    await OfflineMediaCache.instance.cacheFromUrl(
      bucket: 'post-media',
      objectPath: objectPath,
      signedUrl: signedUrl,
      isVideo: false,
    );
  }

  // BOOTFIX: the profile only needs to be verified once per session. It used
  // to run 3+ times on every launch, each time costing network round trips.
  String? _ensuredFor;
  Future<Map<String, dynamic>>? _ensuring;

  Future<Map<String, dynamic>> ensureProfile() {
    final uid = _db.auth.currentUser?.id;
    final running = _ensuring;
    if (running != null && _ensuredFor == uid) return running;
    _ensuredFor = uid;
    final work = _ensureProfileImpl();
    _ensuring = work;
    work.then<void>((_) {}, onError: (Object _) {
      if (identical(_ensuring, work)) _ensuring = null;
    });
    return work;
  }

  /// One local-cache check per path, then ONE batched signing request per
  /// 100 paths (instead of one HTTP request per image).
  Future<Map<String, String>> _resolvePaths(
    String bucket,
    Iterable<String> paths, {
    bool strict = false,
  }) async {
    final unique = paths.where((p) => p.isNotEmpty).toSet().toList();
    final result = <String, String>{};
    final missing = <String>[];
    await Future.wait<void>(
      unique.map((path) async {
        final local = await OfflineMediaCache.instance.existingUri(
          bucket,
          path,
        );
        if (local != null) {
          result[path] = local;
        } else {
          missing.add(path);
        }
      }),
    );
    for (var i = 0; i < missing.length; i += 100) {
      final chunk = missing.sublist(i, min(i + 100, missing.length));
      try {
        final signed = await _db.storage
            .from(bucket)
            // ignore: deprecated_member_use
            .createSignedUrls(chunk, 3600)
            .timeout(const Duration(seconds: 15));
        for (final item in signed) {
          final url = item.signedUrl;
          if (url.contains('token=')) result[item.path.toString()] = url;
        }
      } catch (e) {
        if (strict) rethrow;
      }
    }
    return result;
  }

  static bool _isStoragePath(String value) =>
      value.isNotEmpty &&
      value != 'pending' &&
      !value.startsWith('http://') &&
      !value.startsWith('https://');

  Future<Map<String, dynamic>> _ensureProfileImpl() async {
    final user = _db.auth.currentUser;
    if (user == null) throw AuthException('Please sign in again.');
    final existing = await _db
        .from('profiles')
        .select()
        .eq('id', user.id)
        .maybeSingle();
    final meta = user.userMetadata ?? const <String, dynamic>{};
    if (existing != null) {
      final row = Map<String, dynamic>.from(existing);
      final currentName = (row['display_name'] ?? '').toString().trim();
      final metadataName = (meta['name'] ?? meta['full_name'] ?? '')
          .toString()
          .trim();
      if (currentName.isEmpty && metadataName.isNotEmpty) {
        await _db
            .from('profiles')
            .update({'display_name': metadataName})
            .eq('id', user.id);
        row['display_name'] = metadataName;
      }
      return await _resolveProfileAvatar(row);
    }
    final baseRaw = _slug(
      (meta['name'] ??
              meta['full_name'] ??
              user.email?.split('@').first ??
              'twice_user')
          .toString(),
    );
    final base = baseRaw.length > 20 ? baseRaw.substring(0, 20) : baseRaw;
    var username = base.isEmpty ? 'twice_user' : base;
    for (var i = 0; i < 5; i++) {
      final found = await _db
          .from('profiles')
          .select('id')
          .eq('username', username)
          .maybeSingle();
      if (found == null) break;
      username =
          '${base.isEmpty ? 'twice_user' : base}_${user.id.substring(0, 4 + i)}';
    }
    final display = (meta['name'] ?? meta['full_name'] ?? username)
        .toString()
        .trim();
    await _db
        .from('profiles')
        .upsert(
          {
            'id': user.id,
            'username': username,
            'display_name': display.isEmpty ? username : display,
          },
          onConflict: 'id',
          ignoreDuplicates: true,
        );
    final result = await _db
        .from('profiles')
        .select()
        .eq('id', user.id)
        .single();
    return await _resolveProfileAvatar(Map<String, dynamic>.from(result));
  }

  String _slug(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleaned.length > 24 ? cleaned.substring(0, 24) : cleaned;
  }

  Future<Map<String, dynamic>> myProfile() async {
    try {
      final ensured = await ensureProfile();
      await _cache.put(userId, 'profile', ensured);
      return ensured;
    } catch (e) {
      if (_looksLikeNetworkFailure(e)) {
        final cached = await cachedMyProfile();
        if (cached != null) return cached;
      }
      rethrow;
    }
  }

  Future<void> updateProfile({
    required String displayName,
    required String username,
    required String bio,
    AssetEntity? avatarAsset,
  }) async {
    final clean = username.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(clean)) {
      throw const FormatException(
        'Username must be 3–30 characters using letters, numbers, or underscores.',
      );
    }

    final values = <String, dynamic>{
      'display_name': displayName.trim(),
      'username': clean,
      'bio': bio.trim(),
    };

    if (avatarAsset != null) {
      final file = await avatarAsset.file;
      if (file == null) {
        throw Exception('Could not read the selected profile photo.');
      }
      final ext = file.path.split('.').last.toLowerCase();
      final objectPath =
          '$userId/avatar_${DateTime.now().microsecondsSinceEpoch}.$ext';

      await _db.storage
          .from('post-media')
          .upload(
            objectPath,
            file,
            fileOptions: FileOptions(contentType: _mime(ext), upsert: false),
          );

      // Store the storage path, not an expiring signed URL.
      values['avatar_url'] = objectPath;
      try {
        await _db.from('profiles').update(values).eq('id', userId);
      } catch (_) {
        try {
          await _db.storage.from('post-media').remove([objectPath]);
        } catch (_) {}
        rethrow;
      }
    } else {
      await _db.from('profiles').update(values).eq('id', userId);
    }
    try {
      await _cache.put(userId, 'profile', await myProfile());
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> feed({
    int limit = 30,
    int offset = 0,
  }) async {
    try {
      final rows = await _db
          .from('posts')
          .select(
            'id,user_id,caption,visibility,comments_enabled,created_at,profiles!posts_user_id_fkey(id,username,display_name,avatar_url),post_media(id,media_url,thumbnail_url,media_type,position),post_likes(user_id),saved_posts(user_id),comments(count)',
          )
          .order('created_at', ascending: false)
          .range(offset, offset + limit - 1)
          .timeout(const Duration(seconds: 25));

      final posts = (rows as List)
          .map((raw) => Map<String, dynamic>.from(raw as Map))
          .toList();

      // BOOTFIX: collect every storage path once (authors repeat across posts),
      // then sign them all with a single batched request.
      final needed = <String>{};
      for (final post in posts) {
        final author = post['profiles'];
        if (author is Map) {
          final path = (author['avatar_url'] ?? '').toString().trim();
          if (_isStoragePath(path)) needed.add(path);
        }
        for (final media in (post['post_media'] as List? ?? const [])) {
          if (media is! Map) continue;
          for (final key in const ['media_url', 'thumbnail_url']) {
            final path = (media[key] ?? '').toString().trim();
            if (_isStoragePath(path)) needed.add(path);
          }
        }
      }
      // strict: if signing fails the caller keeps showing the cached feed.
      final urls = await _resolvePaths('post-media', needed, strict: true);

      String resolve(String path) {
        if (path.isEmpty) return '';
        if (!_isStoragePath(path)) return path;
        return urls[path] ?? '';
      }

      for (final post in posts) {
        final authorRaw = post['profiles'];
        if (authorRaw is Map) {
          final author = Map<String, dynamic>.from(authorRaw);
          final path = (author['avatar_url'] ?? '').toString().trim();
          author['avatar_object_path'] = _isStoragePath(path) ? path : '';
          author['avatar_url'] = resolve(path);
          post['profiles'] = author;
        }
        post['media_resolved'] = (post['post_media'] as List? ?? const [])
            .whereType<Map>()
            .map((raw) {
              final item = Map<String, dynamic>.from(raw);
              item['resolved_url'] = resolve(
                (item['media_url'] ?? '').toString().trim(),
              );
              item['resolved_thumbnail_url'] = resolve(
                (item['thumbnail_url'] ?? '').toString().trim(),
              );
              return item;
            })
            .toList();
      }

      // Preserve local pending changes so stale network responses cannot overwrite them.
      final mergedPosts = await _applyPendingToPosts(userId, posts);
      await _cache.put(userId, 'feed', mergedPosts);

      // Prefetch only after the screen is already drawn, so it never competes
      // with the first paint for bandwidth.
      unawaited(
        Future<void>.delayed(
          const Duration(seconds: 4),
          () => _warmFeedMediaCache(mergedPosts),
        ).catchError((Object _) {}),
      );
      return mergedPosts;
    } catch (error) {
      if (_looksLikeNetworkFailure(error)) {
        return cachedFeed();
      }
      rethrow;
    }
  }

  // FBFIX: lightweight, bounded prefetch of photos + thumbnails (3 at a time).
  // Videos stream and are cached by the player when watched.
  Future<void> _warmFeedMediaCache(List<Map<String, dynamic>> feedRows) async {
    final jobs = <Future<void> Function()>[];
    Future<void> add(String path, String url, bool video) async {
      if (path.isEmpty || url.isEmpty || url.startsWith('file://')) return;
      await OfflineMediaCache.instance.cacheFromUrl(
        bucket: 'post-media',
        objectPath: path,
        signedUrl: url,
        isVideo: video,
      );
    }

    for (final post in feedRows.take(40)) {
      for (final raw in (post['media_resolved'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final type = (raw['media_type'] ?? '').toString().toLowerCase();
        final path = (raw['media_url'] ?? '').toString().trim();
        final url = (raw['resolved_url'] ?? '').toString().trim();
        final thumbPath = (raw['thumbnail_url'] ?? '').toString().trim();
        final thumbUrl = (raw['resolved_thumbnail_url'] ?? '').toString().trim();
        jobs.add(() => add(thumbPath, thumbUrl, false));
        if (type != 'video') jobs.add(() => add(path, url, false));
      }
    }
    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        final job = jobs[next++];
        try {
          await job();
        } catch (_) {}
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
  }

  /// Refreshes a storage object's URL, preferring a complete offline copy.
  /// Returns null when the object cannot be resolved.
  Future<String?> refreshMediaUrl(
    String objectPath, {
    String bucket = 'post-media',
  }) async {
    final path = objectPath.trim();
    if (path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }

    try {
      final local = await OfflineMediaCache.instance.existingUri(bucket, path);
      if (local != null) return local;
      return await _db.storage.from(bucket).createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeNetworkFailure(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('socketexception') ||
        text.contains('failed host lookup') ||
        text.contains('clientexception') ||
        text.contains('connection reset') ||
        text.contains('connection refused') ||
        text.contains('connection aborted') ||
        text.contains('connection closed') ||
        text.contains('connection terminated') ||
        text.contains('network is unreachable') ||
        text.contains('no address associated with hostname') ||
        text.contains('handshakeexception') ||
        text.contains('broken pipe') ||
        text.contains('socket is not connected') ||
        text.contains('software caused connection abort') ||
        text.contains('timed out') ||
        text.contains('timeout');
  }

  Future<void> _applyLikeState(String postId, bool liked) async {
    if (liked) {
      await _db
          .from('post_likes')
          .upsert(
            {'post_id': postId, 'user_id': userId},
            onConflict: 'post_id,user_id',
            ignoreDuplicates: true,
          );
    } else {
      await _db
          .from('post_likes')
          .delete()
          .eq('post_id', postId)
          .eq('user_id', userId);
    }
  }

  /// Applies the requested state, queueing only likely connectivity failures.
  /// The payload is a desired state, not a toggle, so retries are idempotent.
  Future<void> setLikeState(String postId, bool liked) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw AuthException('Please sign in again.');

    try {
      await _applyLikeState(postId, liked);
      final pending = await _cache.pending(uid);
      for (final item in pending) {
        if (item['operation'] == 'set_like' &&
            item['payload'] is Map &&
            item['payload']['post_id'] == postId) {
          await _cache.removePending(item['id'].toString());
        }
      }
    } catch (error) {
      if (!_looksLikeNetworkFailure(error)) rethrow;
      await _cache.enqueue(uid, 'set_like', {
        'post_id': postId,
        'liked': liked,
      });
    }
    await _updateCachedLike(postId, liked);
  }

  /// Kept for existing callers: currentlyLiked is the state before the tap.
  Future<void> toggleLike(String postId, bool currentlyLiked) async {
    await setLikeState(postId, !currentlyLiked);
  }

  Future<void> _updateCachedLike(String postId, bool liked) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    final cached = await _cache.get(uid, 'feed');
    if (cached is! List) return;

    final updated = <Map<String, dynamic>>[];
    for (final raw in cached) {
      if (raw is! Map) continue;
      final post = Map<String, dynamic>.from(raw);
      if (post['id']?.toString() == postId) {
        final likes = List<Map<String, dynamic>>.from(
          (post['post_likes'] as List? ?? const []).whereType<Map>().map(
            (row) => Map<String, dynamic>.from(row),
          ),
        );
        likes.removeWhere((row) => row['user_id']?.toString() == uid);
        if (liked) likes.add({'user_id': uid});
        post['post_likes'] = likes;
      }
      updated.add(post);
    }
    await _cache.put(uid, 'feed', updated);
  }

  /// Replays queued likes, bookmarks, and comments for the signed-in account.
  Future<void> syncPendingLikes() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;

    final pending = await _cache.pending(uid);
    for (final item in pending) {
      if (item['operation'] != 'set_like' &&
          item['operation'] != 'set_saved' &&
          item['operation'] != 'add_comment') {
        continue;
      }
      try {
        final payload = Map<String, dynamic>.from(item['payload'] as Map);
        if (item['operation'] == 'add_comment') {
          await _db
              .from('comments')
              .upsert(payload, onConflict: 'id', ignoreDuplicates: true)
              .timeout(const Duration(seconds: 15));
          await _cache.removePending(item['id'].toString());
          continue;
        }
        if (item['operation'] == 'set_saved') {
          final postId = payload['post_id']?.toString();
          if (postId != null && postId.isNotEmpty) {
            final saved = payload['saved'] == true;
            if (saved) {
              await _db
                  .from('saved_posts')
                  .upsert({'post_id': postId, 'user_id': uid},
                      onConflict: 'user_id,post_id', ignoreDuplicates: true)
                  .timeout(const Duration(seconds: 15));
            } else {
              await _db
                  .from('saved_posts')
                  .delete()
                  .eq('post_id', postId)
                  .eq('user_id', uid)
                  .timeout(const Duration(seconds: 15));
            }
            await _updateCachedSaved(postId, saved);
          }
          await _cache.removePending(item['id'].toString());
          continue;
        }
        final postId = payload['post_id']?.toString();
        if (postId == null || postId.isEmpty) {
          await _cache.removePending(item['id'].toString());
          continue;
        }
        final liked = payload['liked'] == true;
        await _applyLikeState(postId, liked);
        await _updateCachedLike(postId, liked);
        await _cache.removePending(item['id'].toString());
      } catch (error) {
        await _cache.markFailed(item['id'].toString(), error);
        if (_looksLikeNetworkFailure(error)) break;
        // A permanent policy/schema error should not block unrelated queued
        // operations. Keep the row for diagnostics and continue with the next.
      }
    }
  }

  Future<void> toggleSaved(String postId, bool saved) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw AuthException('Please sign in again.');
    final newSaved = !saved;

    try {
      if (saved) {
        await _db
            .from('saved_posts')
            .delete()
            .eq('post_id', postId)
            .eq('user_id', uid)
            .timeout(const Duration(seconds: 15));
      } else {
        await _db
            .from('saved_posts')
            .upsert(
              {'post_id': postId, 'user_id': uid},
              onConflict: 'user_id,post_id',
              ignoreDuplicates: true,
            )
            .timeout(const Duration(seconds: 15));
      }
      final pending = await _cache.pending(uid);
      for (final item in pending) {
        if (item['operation'] == 'set_saved' &&
            item['payload'] is Map &&
            item['payload']['post_id'] == postId) {
          await _cache.removePending(item['id'].toString());
        }
      }
    } catch (error) {
      if (!_looksLikeNetworkFailure(error)) rethrow;
      await _cache.enqueue(uid, 'set_saved', {
        'post_id': postId,
        'saved': newSaved,
      });
    }
    await _updateCachedSaved(postId, newSaved);
  }

  Future<void> _updateCachedSaved(String postId, bool saved) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    final cached = await _cache.get(uid, 'feed');
    if (cached is! List) return;

    final updated = <Map<String, dynamic>>[];
    for (final raw in cached) {
      if (raw is! Map) continue;
      final post = Map<String, dynamic>.from(raw);
      if (post['id']?.toString() == postId) {
        final savedRows = List<Map<String, dynamic>>.from(
          (post['saved_posts'] as List? ?? const []).whereType<Map>().map(
            (row) => Map<String, dynamic>.from(row),
          ),
        );
        savedRows.removeWhere((row) => row['user_id']?.toString() == uid);
        if (saved) savedRows.add({'user_id': uid});
        post['saved_posts'] = savedRows;
      }
      updated.add(post);
    }
    await _cache.put(uid, 'feed', updated);
  }

  Future<String> publishPost(
    String caption,
    List<AssetEntity> assets, {
    String visibility = 'public',
  }) async {
    final text = caption.trim();
    if (text.isEmpty && assets.isEmpty) {
      throw const FormatException('Add a caption or select media.');
    }
    final created = await _db
        .from('posts')
        .insert({'user_id': userId, 'caption': text, 'visibility': visibility})
        .select('id')
        .single();
    final postId = created['id'].toString();
    final uploadedPaths = <String>[];
    try {
      var position = 0;
      for (final asset in assets) {
        final file = await asset.file;
        if (file == null) continue;
        final ext = file.path.split('.').last.toLowerCase();
        final type = asset.type == AssetType.video
            ? 'video'
            : (ext == 'gif' ? 'gif' : 'image');
        final objectPath =
            '$userId/$postId/${DateTime.now().microsecondsSinceEpoch}_$position.$ext';
        await _db.storage
            .from('post-media')
            .upload(
              objectPath,
              file,
              fileOptions: FileOptions(contentType: _mime(ext), upsert: false),
            );
        uploadedPaths.add(objectPath);

        String? thumbnailPath;
        if (type == 'video') {
          try {
            final bytes = await VideoThumbnail.thumbnailData(
              video: file.path,
              imageFormat: ImageFormat.JPEG,
              maxWidth: 720,
              quality: 78,
            );
            if (bytes != null && bytes.isNotEmpty) {
              final candidate =
                  '$userId/$postId/${DateTime.now().microsecondsSinceEpoch}_${position}_thumb.jpg';
              await _db.storage
                  .from('post-media')
                  .uploadBinary(
                    candidate,
                    bytes,
                    fileOptions: const FileOptions(
                      contentType: 'image/jpeg',
                      upsert: false,
                    ),
                  );
              uploadedPaths.add(candidate);
              thumbnailPath = candidate;
            }
          } catch (_) {
            // Thumbnail extraction is optional; preserve the video upload.
          }
        }

        await _db.from('post_media').insert({
          'post_id': postId,
          'media_url': objectPath,
          'thumbnail_url': thumbnailPath,
          'media_type': type,
          'position': position,
        });
        position++;
      }
      return postId;
    } catch (_) {
      // Avoid leaving a half-created post or orphaned storage objects.
      if (uploadedPaths.isNotEmpty) {
        try {
          await _db.storage.from('post-media').remove(uploadedPaths);
        } catch (_) {}
      }
      await _db.from('posts').delete().eq('id', postId);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> loadStories() async {
    try {
      final rows = await _db
          .from('stories')
          .select(
            'id,user_id,media_url,media_type,caption,created_at,expires_at',
          )
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: true)
          .timeout(const Duration(seconds: 15));

      final stories = (rows as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();

      if (stories.isEmpty) {
        final uid = _db.auth.currentUser?.id;
        if (uid != null) await _cache.put(uid, 'stories', stories);
        return stories;
      }

      final ids = stories
          .map((story) => story['user_id'].toString())
          .toSet()
          .toList();

      final profiles = await _db
          .from('profiles')
          .select('id,username,display_name,avatar_url')
          .inFilter('id', ids)
          .timeout(const Duration(seconds: 15));

      // BOOTFIX: resolve all avatars and story media with batched requests
      // (this used to be one sequential HTTP request per story).
      final profileRows = (profiles as List)
          .map((raw) => Map<String, dynamic>.from(raw as Map))
          .toList();
      final avatarUrls = await _resolvePaths('post-media', [
        for (final row in profileRows)
          if (_isStoragePath((row['avatar_url'] ?? '').toString().trim()))
            (row['avatar_url'] ?? '').toString().trim(),
      ]);
      final byId = <String, Map<String, dynamic>>{};
      for (final row in profileRows) {
        final path = (row['avatar_url'] ?? '').toString().trim();
        row['avatar_object_path'] = _isStoragePath(path) ? path : '';
        row['avatar_url'] =
            _isStoragePath(path) ? (avatarUrls[path] ?? '') : path;
        byId[row['id'].toString()] = row;
      }

      final storyUrls = await _resolvePaths('stories', [
        for (final story in stories)
          if (_isStoragePath((story['media_url'] ?? '').toString()))
            (story['media_url'] ?? '').toString(),
      ]);
      for (final story in stories) {
        story['profiles'] = byId[story['user_id'].toString()] ?? {};
        final path = (story['media_url'] ?? '').toString();
        story['resolved_url'] = _isStoragePath(path)
            ? (storyUrls[path] ?? '')
            : (path == 'pending' ? '' : path);
      }

      final uid = _db.auth.currentUser?.id;
      if (uid != null) await _cache.put(uid, 'stories', stories);
      return stories;
    } catch (e) {
      if (_looksLikeNetworkFailure(e)) {
        return cachedStories();
      }
      rethrow;
    }
  }

  // ---- Story views, likes and replies ----
  Future<void> recordStoryView(String storyId) async {
    try {
      await _db.from('story_views').upsert({
        'story_id': storyId,
        'viewer_id': userId,
      }, onConflict: 'story_id,viewer_id', ignoreDuplicates: true);
    } catch (_) {}
  }

  /// Ids (out of [storyIds]) that the signed-in user has already viewed.
  /// Used so the story ring turns grey on every device, not just this one.
  Future<Set<String>> myViewedStoryIds(Iterable<String> storyIds) async {
    final ids = storyIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return <String>{};
    final rows = await _db
        .from('story_views')
        .select('story_id')
        .eq('viewer_id', userId)
        .inFilter('story_id', ids)
        .timeout(const Duration(seconds: 15));
    return (rows as List)
        .map((row) => (row as Map)['story_id'].toString())
        .toSet();
  }

  Future<int> storyViewCount(String storyId) async {
    final rows = await _db
        .from('story_views')
        .select('viewer_id')
        .eq('story_id', storyId)
        .timeout(const Duration(seconds: 15));
    return (rows as List).length;
  }

  Future<bool> myStoryLike(String storyId) async {
    final rows = await _db
        .from('story_reactions')
        .select('story_id')
        .eq('story_id', storyId)
        .eq('user_id', userId)
        .limit(1)
        .timeout(const Duration(seconds: 15));
    return (rows as List).isNotEmpty;
  }

  Future<void> setStoryLike(String storyId, bool liked) async {
    if (liked) {
      await _db.from('story_reactions').upsert({
        'story_id': storyId,
        'user_id': userId,
        'reaction': '❤️',
      }, onConflict: 'story_id,user_id', ignoreDuplicates: true);
    } else {
      await _db
          .from('story_reactions')
          .delete()
          .eq('story_id', storyId)
          .eq('user_id', userId);
    }
  }

  /// Sends the reply as a direct message to the story owner.
  Future<void> replyToStory(String ownerId, String text) async {
    final conversationId = await createConversation(ownerId);
    await sendMessage(conversationId, 'Replied to your story: ${text.trim()}');
  }

  Future<List<Map<String, dynamic>>> storyViewers(String storyId) async {
    final views = await _db
        .from('story_views')
        .select('viewer_id,viewed_at')
        .eq('story_id', storyId)
        .order('viewed_at', ascending: false)
        .limit(300)
        .timeout(const Duration(seconds: 15));
    final viewRows = (views as List)
        .map((raw) => Map<String, dynamic>.from(raw as Map))
        .toList();
    if (viewRows.isEmpty) return [];
    final ids = viewRows.map((v) => v['viewer_id'].toString()).toList();

    final profileRows = await _db
        .from('profiles')
        .select('id,username,display_name,avatar_url')
        .inFilter('id', ids)
        .timeout(const Duration(seconds: 15));
    final reactions = await _db
        .from('story_reactions')
        .select('user_id')
        .eq('story_id', storyId)
        .timeout(const Duration(seconds: 15));
    final likedBy = {
      for (final r in reactions as List) (r as Map)['user_id'].toString(),
    };

    final profiles = {
      for (final raw in profileRows as List)
        (raw as Map)['id'].toString(): Map<String, dynamic>.from(raw),
    };
    final avatarUrls = await _resolvePaths('post-media', [
      for (final p in profiles.values)
        if (_isStoragePath((p['avatar_url'] ?? '').toString().trim()))
          (p['avatar_url'] ?? '').toString().trim(),
    ]);
    return [
      for (final v in viewRows)
        () {
          final profile = Map<String, dynamic>.from(
            profiles[v['viewer_id'].toString()] ?? const {},
          );
          final path = (profile['avatar_url'] ?? '').toString().trim();
          if (_isStoragePath(path)) profile['avatar_url'] = avatarUrls[path] ?? '';
          return <String, dynamic>{
            'profile': profile,
            'viewed_at': v['viewed_at'],
            'liked': likedBy.contains(v['viewer_id'].toString()),
          };
        }(),
    ];
  }

  Future<void> publishStory(AssetEntity asset, String caption) async {
    if (asset.type == AssetType.video && asset.duration > 60) {
      throw Exception('Stories can be up to 60 seconds long.');
    }
    final file = await asset.file;
    if (file == null) {
      throw Exception('Could not read the selected story media.');
    }

    final ext = file.path.split('.').last.toLowerCase();
    final storyId = await _db
        .from('stories')
        .insert({
          'user_id': userId,
          'media_url': 'pending',
          'media_type': asset.type == AssetType.video ? 'video' : 'image',
          'caption': caption.trim(),
        })
        .select('id')
        .single();

    final id = storyId['id'].toString();
    final objectPath =
        '$userId/$id/${DateTime.now().microsecondsSinceEpoch}.$ext';

    try {
      await _db.storage
          .from('stories')
          .upload(
            objectPath,
            file,
            fileOptions: FileOptions(contentType: _mime(ext), upsert: false),
          );

      await _db.from('stories').update({'media_url': objectPath}).eq('id', id);
    } catch (_) {
      try {
        await _db.storage.from('stories').remove([objectPath]);
      } catch (_) {}
      try {
        await _db.from('stories').delete().eq('id', id);
      } catch (_) {}
      rethrow;
    }
  }

  String _mime(String ext) => switch (ext) {
    'jpg' => 'image/jpeg',
    'jpeg' => 'image/jpeg',
    'jpe' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'mp4' => 'video/mp4',
    'm4v' => 'video/x-m4v',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'mkv' => 'video/x-matroska',
    '3gp' => 'video/3gpp',
    'heic' => 'image/heic',
    'heif' => 'image/heif',
    'avif' => 'image/avif',
    _ => 'application/octet-stream',
  };

  Future<List<Map<String, dynamic>>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final safe = q
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_')
        .replaceAll(',', ' ')
        .replaceAll('(', ' ')
        .replaceAll(')', ' ');
    final results = <Map<String, dynamic>>[];
    final byUsername = await _db
        .from('profiles')
        .select('id,username,display_name,bio,avatar_url,is_private')
        .ilike('username', '%$safe%')
        .limit(20);
    final byName = await _db
        .from('profiles')
        .select('id,username,display_name,bio,avatar_url,is_private')
        .ilike('display_name', '%$safe%')
        .limit(20);
    final usersById = <String, Map<String, dynamic>>{};
    for (final row in [...byUsername, ...byName]) {
      final user = Map<String, dynamic>.from(row as Map);
      usersById[user['id'].toString()] = user;
    }
    results.addAll(usersById.values.map((e) => {...e, 'result_type': 'user'}));
    final posts = await _db
        .from('posts')
        .select(
          'id,user_id,caption,created_at,profiles!posts_user_id_fkey(username,display_name,avatar_url)',
        )
        .ilike('caption', '%$safe%')
        .order('created_at', ascending: false)
        .limit(20);
    results.addAll(
      (posts as List).map(
        (e) => {...Map<String, dynamic>.from(e as Map), 'result_type': 'post'},
      ),
    );
    return results;
  }

  // ───────────────────────── Search & public profiles ─────────────────────────

  static const String _profileColumns =
      'id,username,display_name,bio,avatar_url,is_private';
  static const String _postColumns =
      'id,user_id,caption,visibility,comments_enabled,created_at,'
      'profiles!posts_user_id_fkey(id,username,display_name,avatar_url),'
      'post_media(id,media_url,thumbnail_url,media_type,position),'
      'post_likes(user_id),saved_posts(user_id),comments(count)';

  String _likeSafe(String query) {
    var q = query.trim();
    if (q.startsWith('@')) q = q.substring(1);
    return q
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_')
        .replaceAll(',', ' ')
        .replaceAll('(', ' ')
        .replaceAll(')', ' ')
        .trim();
  }

  /// Adds follower / following counts, the viewer's follow state and a usable
  /// avatar URL (local cache first, then one batched signing request).
  Future<List<Map<String, dynamic>>> _decorateProfiles(
    List<Map<String, dynamic>> profiles,
  ) async {
    if (profiles.isEmpty) return profiles;
    final me = userId;
    final ids = profiles.map((p) => p['id'].toString()).toList();

    final values = await Future.wait<List<dynamic>>([
      _db
          .from('follows')
          .select('follower_id,following_id')
          .inFilter('following_id', ids)
          .eq('status', 'accepted'),
      _db
          .from('follows')
          .select('follower_id,following_id')
          .inFilter('follower_id', ids)
          .eq('status', 'accepted'),
      _db
          .from('follows')
          .select('following_id,status')
          .eq('follower_id', me)
          .inFilter('following_id', ids),
      _db
          .from('follows')
          .select('follower_id')
          .eq('following_id', me)
          .eq('status', 'accepted')
          .inFilter('follower_id', ids),
    ]).timeout(const Duration(seconds: 20));

    final followers = <String, int>{};
    for (final row in values[0]) {
      final id = (row as Map)['following_id'].toString();
      followers[id] = (followers[id] ?? 0) + 1;
    }
    final following = <String, int>{};
    for (final row in values[1]) {
      final id = (row as Map)['follower_id'].toString();
      following[id] = (following[id] ?? 0) + 1;
    }
    final outgoing = <String, String>{};
    for (final row in values[2]) {
      final map = row as Map;
      outgoing[map['following_id'].toString()] = (map['status'] ?? '')
          .toString();
    }
    final followsMe = <String>{
      for (final row in values[3]) (row as Map)['follower_id'].toString(),
    };

    final paths = <String>{};
    for (final p in profiles) {
      final raw = (p['avatar_url'] ?? '').toString().trim();
      if (_isStoragePath(raw)) paths.add(raw);
    }
    final urls = await _resolvePaths('post-media', paths);

    for (final p in profiles) {
      final id = p['id'].toString();
      final raw = (p['avatar_url'] ?? '').toString().trim();
      final storage = _isStoragePath(raw);
      p['avatar_raw'] = raw;
      p['avatar_object_path'] = storage ? raw : '';
      p['avatar_url'] = storage ? (urls[raw] ?? '') : raw;
      p['followers_count'] = followers[id] ?? 0;
      p['following_count'] = following[id] ?? 0;
      final status = outgoing[id] ?? '';
      p['follow_label'] = id == me
          ? ''
          : status == 'pending'
          ? 'Requested'
          : status == 'accepted'
          ? 'Following'
          : followsMe.contains(id)
          ? 'Follow Back'
          : 'Follow';
    }
    return profiles;
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) => value is List
      ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : <Map<String, dynamic>>[];

  /// People search by name or @username. Best matches first.
  Future<List<Map<String, dynamic>>> searchPeople(
    String query, {
    int limit = 30,
  }) async {
    final safe = _likeSafe(query);
    if (safe.isEmpty) return [];
    final lower = safe.toLowerCase();
    try {
      final responses = await Future.wait<List<dynamic>>([
        _db
            .from('profiles')
            .select(_profileColumns)
            .ilike('username', '%$safe%')
            .limit(limit),
        _db
            .from('profiles')
            .select(_profileColumns)
            .ilike('display_name', '%$safe%')
            .limit(limit),
      ]).timeout(const Duration(seconds: 20));
      final byId = <String, Map<String, dynamic>>{};
      for (final list in responses) {
        for (final row in list) {
          final map = Map<String, dynamic>.from(row as Map);
          byId[map['id'].toString()] = map;
        }
      }
      int rank(Map<String, dynamic> p) {
        final u = (p['username'] ?? '').toString().toLowerCase();
        final n = (p['display_name'] ?? '').toString().toLowerCase();
        if (u == lower || n == lower) return 0;
        if (u.startsWith(lower)) return 1;
        if (n.startsWith(lower)) return 2;
        return 3;
      }

      final sorted = byId.values.toList()
        ..sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          if (r != 0) return r;
          return (a['username'] ?? '').toString().compareTo(
            (b['username'] ?? '').toString(),
          );
        });
      final out = await _decorateProfiles(sorted.take(limit).toList());
      unawaited(
        _cache
            .put(userId, 'search_people', out, id: lower)
            .catchError((Object _) {}),
      );
      return out;
    } catch (e) {
      if (_looksLikeNetworkFailure(e)) {
        final cached = _asMapList(
          await _cache.get(userId, 'search_people', id: lower),
        );
        if (cached.isNotEmpty) return cached;
      }
      rethrow;
    }
  }

  /// People the viewer may want to follow (newest accounts first).
  Future<List<Map<String, dynamic>>> suggestedPeople({int limit = 20}) async {
    try {
      final rows = await _db
          .from('profiles')
          .select(_profileColumns)
          .neq('id', userId)
          .order('created_at', ascending: false)
          .limit(60)
          .timeout(const Duration(seconds: 20));
      final profiles = _asMapList(rows);
      final decorated = await _decorateProfiles(profiles);
      final out = decorated
          .where(
            (p) =>
                p['follow_label'] != 'Following' &&
                p['follow_label'] != 'Requested',
          )
          .take(limit)
          .toList();
      unawaited(
        _cache
            .put(userId, 'search_suggested', out)
            .catchError((Object _) {}),
      );
      return out;
    } catch (e) {
      if (_looksLikeNetworkFailure(e)) {
        return _asMapList(await _cache.get(userId, 'search_suggested'));
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _rawRecents() async =>
      _asMapList(await _cache.get(userId, 'search_recent'));

  /// Recently opened profiles, resolved to a usable (cached) avatar.
  Future<List<Map<String, dynamic>>> recentSearchProfiles() async {
    final list = await _rawRecents();
    final paths = <String>{
      for (final p in list)
        if (_isStoragePath((p['avatar_raw'] ?? '').toString().trim()))
          (p['avatar_raw'] ?? '').toString().trim(),
    };
    final urls = paths.isEmpty
        ? <String, String>{}
        : await _resolvePaths('post-media', paths);
    for (final p in list) {
      final raw = (p['avatar_raw'] ?? '').toString().trim();
      p['avatar_url'] = _isStoragePath(raw) ? (urls[raw] ?? '') : raw;
    }
    return list;
  }

  Future<void> addRecentSearchProfile(Map<String, dynamic> profile) async {
    final id = (profile['id'] ?? '').toString();
    if (id.isEmpty) return;
    final list = await _rawRecents();
    list.removeWhere((p) => p['id'].toString() == id);
    list.insert(0, {
      'id': id,
      'username': profile['username'],
      'display_name': profile['display_name'],
      'avatar_raw': (profile['avatar_raw'] ?? profile['avatar_object_path'] ?? '')
          .toString(),
      'is_private': profile['is_private'] == true,
    });
    await _cache.put(userId, 'search_recent', list.take(12).toList());
  }

  Future<void> removeRecentSearchProfile(String id) async {
    final list = await _rawRecents();
    list.removeWhere((p) => p['id'].toString() == id);
    await _cache.put(userId, 'search_recent', list);
  }

  Future<void> clearRecentSearchProfiles() async =>
      _cache.put(userId, 'search_recent', <Map<String, dynamic>>[]);

  /// Signs media for a batch of post rows and shapes them like feed() rows.
  Future<List<Map<String, dynamic>>> _hydratePosts(
    List<Map<String, dynamic>> posts,
  ) async {
    final needed = <String>{};
    for (final post in posts) {
      final author = post['profiles'];
      if (author is Map) {
        final path = (author['avatar_url'] ?? '').toString().trim();
        if (_isStoragePath(path)) needed.add(path);
      }
      for (final media in (post['post_media'] as List? ?? const [])) {
        if (media is! Map) continue;
        for (final key in const ['media_url', 'thumbnail_url']) {
          final path = (media[key] ?? '').toString().trim();
          if (_isStoragePath(path)) needed.add(path);
        }
      }
    }
    final urls = await _resolvePaths('post-media', needed);
    String resolve(String path) {
      if (path.isEmpty) return '';
      if (!_isStoragePath(path)) return path;
      return urls[path] ?? '';
    }

    for (final post in posts) {
      final authorRaw = post['profiles'];
      if (authorRaw is Map) {
        final author = Map<String, dynamic>.from(authorRaw);
        final path = (author['avatar_url'] ?? '').toString().trim();
        author['avatar_object_path'] = _isStoragePath(path) ? path : '';
        author['avatar_url'] = resolve(path);
        post['profiles'] = author;
      }
      final media = (post['post_media'] as List? ?? const [])
          .whereType<Map>()
          .map((raw) => Map<String, dynamic>.from(raw))
          .toList()
        ..sort(
          (a, b) => (int.tryParse('${a['position']}') ?? 0).compareTo(
            int.tryParse('${b['position']}') ?? 0,
          ),
        );
      post['media_resolved'] = media.map((item) {
        item['resolved_url'] = resolve(
          (item['media_url'] ?? '').toString().trim(),
        );
        item['resolved_thumbnail_url'] = resolve(
          (item['thumbnail_url'] ?? '').toString().trim(),
        );
        return item;
      }).toList();
    }
    return posts;
  }

  static bool _postHasMedia(Map<String, dynamic> post, {required bool video}) {
    for (final m in (post['post_media'] as List? ?? const [])) {
      if (m is! Map) continue;
      final t = (m['media_type'] ?? '').toString().toLowerCase();
      if (video ? t == 'video' : (t == 'image' || t == 'gif')) return true;
    }
    return false;
  }

  /// Posts matching [query] (caption). With an empty query this is the explore
  /// feed. [kind] is 'all', 'photos' or 'videos'.
  Future<List<Map<String, dynamic>>> searchPosts(
    String query, {
    String kind = 'all',
    int limit = 40,
  }) async {
    final safe = _likeSafe(query);
    var request = _db.from('posts').select(_postColumns);
    if (safe.isNotEmpty) request = request.ilike('caption', '%$safe%');
    final rows = await request
        .order('created_at', ascending: false)
        .limit(kind == 'all' ? limit : 120)
        .timeout(const Duration(seconds: 25));
    var posts = _asMapList(rows);
    if (kind == 'photos') {
      posts = posts.where((p) => _postHasMedia(p, video: false)).toList();
    } else if (kind == 'videos') {
      posts = posts.where((p) => _postHasMedia(p, video: true)).toList();
    }
    return _hydratePosts(posts.take(limit).toList());
  }

  /// Loads and hydrates a single post by its database ID.
  Future<Map<String, dynamic>?> postById(String id) async {
    final key = id.trim();
    if (key.isEmpty) return null;
    final row = await _db
        .from('posts')
        .select(_postColumns)
        .eq('id', key)
        .maybeSingle()
        .timeout(const Duration(seconds: 20));
    if (row == null) return null;
    final hydrated = await _hydratePosts(
      [Map<String, dynamic>.from(row)],
    );
    return hydrated.isEmpty ? null : hydrated.first;
  }

  /// Fresh profile row (avatar resolved) for any user.
  Future<Map<String, dynamic>?> profileById(String id) async {
    final row = await _db
        .from('profiles')
        .select(_profileColumns)
        .eq('id', id)
        .maybeSingle()
        .timeout(const Duration(seconds: 15));
    if (row == null) return null;
    final profile = Map<String, dynamic>.from(row);
    final raw = (profile['avatar_url'] ?? '').toString().trim();
    profile['avatar_raw'] = raw;
    return _resolveProfileAvatar(profile);
  }

  /// Followers, following and post counts that the viewer is allowed to see.
  Future<Map<String, int>> profileStats(String id) async {
    final values = await Future.wait<List<dynamic>>([
      _db
          .from('follows')
          .select('follower_id')
          .eq('following_id', id)
          .eq('status', 'accepted'),
      _db
          .from('follows')
          .select('following_id')
          .eq('follower_id', id)
          .eq('status', 'accepted'),
      _db.from('posts').select('id').eq('user_id', id),
    ]).timeout(const Duration(seconds: 20));
    return {
      'followers': values[0].length,
      'following': values[1].length,
      'posts': values[2].length,
    };
  }

  /// Every post of [profileId] the viewer is allowed to see (RLS enforced).
  Future<List<Map<String, dynamic>>> userPosts(
    String profileId, {
    int limit = 120,
  }) async {
    final rows = await _db
        .from('posts')
        .select(_postColumns)
        .eq('user_id', profileId)
        .order('created_at', ascending: false)
        .limit(limit)
        .timeout(const Duration(seconds: 25));
    return _hydratePosts(_asMapList(rows));
  }

  Future<String> getFollowLabel(String profileId) async {
    if (profileId.isEmpty || profileId == userId) return '';

    final outgoing = await _db
        .from('follows')
        .select('status')
        .eq('follower_id', userId)
        .eq('following_id', profileId)
        .maybeSingle();

    final incoming = await _db
        .from('follows')
        .select('status')
        .eq('follower_id', profileId)
        .eq('following_id', userId)
        .maybeSingle();

    final outgoingStatus = (outgoing?['status'] ?? '').toString();
    final incomingStatus = (incoming?['status'] ?? '').toString();

    if (outgoingStatus == 'pending') return 'Requested';
    final followsMe = incomingStatus == 'accepted';
    final iFollow = outgoingStatus == 'accepted';

    if (iFollow && followsMe) return 'Connected';
    if (iFollow) return 'Following';
    if (followsMe) return 'Follow Back';
    return 'Follow';
  }

  Future<bool> isFollowing(String profileId) async =>
      await _db
          .from('follows')
          .select('follower_id')
          .eq('follower_id', userId)
          .eq('following_id', profileId)
          .eq('status', 'accepted')
          .maybeSingle() !=
      null;

  Future<bool> isConnected(String profileId) async {
    final outgoing = await isFollowing(profileId);
    if (!outgoing) return false;
    final incoming = await _db
        .from('follows')
        .select('follower_id')
        .eq('follower_id', profileId)
        .eq('following_id', userId)
        .eq('status', 'accepted')
        .maybeSingle();
    return incoming != null;
  }

  Future<bool> isPrivateAccount(String profileId) async {
    final row = await _db
        .from('profiles')
        .select('is_private')
        .eq('id', profileId)
        .maybeSingle();
    return row?['is_private'] == true;
  }

  Future<void> follow(String profileId, {required bool privateAccount}) async {
    if (profileId == userId) {
      throw ArgumentError('You cannot follow your own account.');
    }

    final existing = await _db
        .from('follows')
        .select('follower_id')
        .eq('follower_id', userId)
        .eq('following_id', profileId)
        .maybeSingle();

    if (existing != null) return;

    try {
      await _db.from('follows').insert({
        'follower_id': userId,
        'following_id': profileId,
        'status': privateAccount ? 'pending' : 'accepted',
      });
    } on PostgrestException catch (e) {
      // A concurrent tap may have created the same relationship already.
      if (e.code == '23505') return;
      rethrow;
    }
  }

  Future<void> unfollow(String profileId) async {
    await _db
        .from('follows')
        .delete()
        .eq('follower_id', userId)
        .eq('following_id', profileId);
  }

  Future<List<Map<String, dynamic>>> followProfiles({
    required String profileId,
    required bool followers,
  }) async {
    final relationshipColumn = followers ? 'following_id' : 'follower_id';
    final resultColumn = followers ? 'follower_id' : 'following_id';

    final relations = await _db
        .from('follows')
        .select(resultColumn)
        .eq(relationshipColumn, profileId)
        .eq('status', 'accepted');

    final ids = (relations as List)
        .map((row) => (row[resultColumn] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();

    if (ids.isEmpty) return [];

    final rows = await _db
        .from('profiles')
        .select('id,display_name,username,avatar_url,is_private')
        .inFilter('id', ids)
        .order('display_name');

    final profiles = (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();

    final currentUserId = userId;
    final outgoingRows = await _db
        .from('follows')
        .select('following_id,status')
        .eq('follower_id', currentUserId)
        .inFilter('following_id', ids);
    final outgoingStatus = <String, String>{};
    for (final row in outgoingRows as List) {
      outgoingStatus[(row['following_id'] ?? '').toString()] =
          (row['status'] ?? '').toString();
    }

    for (final profile in profiles) {
      final id = (profile['id'] ?? '').toString();
      final status = outgoingStatus[id];
      profile['is_following_back'] = status == 'accepted';
      profile['follow_request_pending'] = status == 'pending';
      profile['is_connected'] = id.isNotEmpty ? await isConnected(id) : false;
      profile['is_current_user'] = id == currentUserId;
    }

    return Future.wait(profiles.map(_resolveProfileAvatar));
  }

  Future<int> commentCount(String postId) async {
    final rows = await _db
        .from('comments')
        .select('id')
        .eq('post_id', postId)
        .timeout(const Duration(seconds: 15));
    return (rows as List).length;
  }

  Future<List<Map<String, dynamic>>> comments(String postId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw AuthException('Please sign in again.');
    try {
      final rows = await _db
          .from('comments')
          .select(
            'id,post_id,user_id,parent_id,body,created_at,profiles!comments_user_id_fkey(id,username,display_name,avatar_url)',
          )
          .eq('post_id', postId)
          .order('created_at')
          .timeout(const Duration(seconds: 15));
      final result = <Map<String, dynamic>>[];
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final rawProfile = row['profiles'];
        if (rawProfile is Map) {
          final profile = Map<String, dynamic>.from(rawProfile);
          if (profile.isNotEmpty) {
            row['profiles'] = await _resolveProfileAvatar(profile);
          }
        } else if (rawProfile is List && rawProfile.isNotEmpty) {
          final profile = Map<String, dynamic>.from(rawProfile.first as Map);
          row['profiles'] = await _resolveProfileAvatar(profile);
        }
        result.add(row);
      }
      final pending = await _cache.pending(uid);
      final cachedProfile = await _cache.get(uid, 'profile');
      for (final item in pending) {
        if (item['operation'] == 'add_comment' &&
            item['payload'] is Map &&
            item['payload']['post_id'] == postId) {
          final payload = Map<String, dynamic>.from(item['payload'] as Map);
          final id = payload['id']?.toString();
          if (!result.any((row) => row['id']?.toString() == id)) {
            result.add({
              ...payload,
              'created_at': DateTime.fromMillisecondsSinceEpoch(
                (item['created_at'] as num?)?.toInt() ??
                    DateTime.now().millisecondsSinceEpoch,
              ).toIso8601String(),
              'profiles': cachedProfile is Map
                  ? Map<String, dynamic>.from(cachedProfile)
                  : <String, dynamic>{},
              '_queued': true,
            });
          }
        }
      }
      await _cache.put(uid, 'comments', result, id: postId);
      return result;
    } catch (error) {
      if (_looksLikeNetworkFailure(error)) {
        return cachedComments(postId);
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> cachedComments(String postId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    final value = await _cache.get(uid, 'comments', id: postId);
    final rows = value is List
        ? value.map((e) => Map<String, dynamic>.from(e as Map)).toList()
        : <Map<String, dynamic>>[];
    final pending = await _cache.pending(uid);
    final cachedProfile = await _cache.get(uid, 'profile');
    for (final item in pending) {
      if (item['operation'] == 'add_comment' &&
          item['payload'] is Map &&
          item['payload']['post_id'] == postId) {
        final payload = Map<String, dynamic>.from(item['payload'] as Map);
        final id = payload['id']?.toString();
        if (!rows.any((row) => row['id']?.toString() == id)) {
          rows.add({
            ...payload,
            'created_at': DateTime.fromMillisecondsSinceEpoch(
              (item['created_at'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch,
            ).toIso8601String(),
            'profiles': cachedProfile is Map
                ? Map<String, dynamic>.from(cachedProfile)
                : <String, dynamic>{},
            '_queued': true,
          });
        }
      }
    }
    return rows;
  }

  String _newCommentId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Returns true when confirmed by Supabase; false when safely queued offline.
  Future<bool> addComment(
    String postId,
    String body, {
    String? commentId,
    String? parentId,
  }) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw AuthException('Please sign in again.');
    final text = body.trim();
    if (text.isEmpty) return true;
    final id = commentId ?? _newCommentId();

    // Use the cached profile for immediate/offline comments. If the profile
    // has not been cached yet, fall back to available auth metadata.
    final cachedProfile = await _cache.get(uid, 'profile');
    final user = _db.auth.currentUser!;
    final metadata = user.userMetadata ?? const <String, dynamic>{};
    final authorProfile = cachedProfile is Map
        ? Map<String, dynamic>.from(cachedProfile)
        : <String, dynamic>{};
    authorProfile['id'] ??= uid;
    authorProfile['username'] ??=
        (metadata['username'] ?? user.email?.split('@').first ?? 'user')
            .toString();
    authorProfile['display_name'] ??=
        (metadata['display_name'] ??
                metadata['name'] ??
                metadata['full_name'] ??
                authorProfile['username'])
            .toString();

    final payload = <String, dynamic>{
      'id': id,
      'post_id': postId,
      'user_id': uid,
      'body': text,
      if (parentId != null && parentId.trim().isNotEmpty)
        'parent_id': parentId.trim(),
    };
    try {
      await _db
          .from('comments')
          .insert(payload)
          .timeout(const Duration(seconds: 15));
      final pending = await _cache.pending(uid);
      for (final item in pending) {
        if (item['operation'] == 'add_comment' &&
            item['payload'] is Map &&
            item['payload']['id'] == id) {
          await _cache.removePending(item['id'].toString());
        }
      }
      final cached = await _cache.get(uid, 'comments', id: postId);
      final rows = cached is List
          ? cached.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : <Map<String, dynamic>>[];
      if (!rows.any((row) => row['id']?.toString() == id)) {
        rows.add({
          ...payload,
          'created_at': DateTime.now().toIso8601String(),
          'profiles': authorProfile,
        });
        await _cache.put(uid, 'comments', rows, id: postId);
      }
      return true;
    } catch (error) {
      if (!_looksLikeNetworkFailure(error)) rethrow;
      await _cache.enqueue(uid, 'add_comment', payload);
      final cached = await _cache.get(uid, 'comments', id: postId);
      final rows = cached is List
          ? cached.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : <Map<String, dynamic>>[];
      if (!rows.any((row) => row['id']?.toString() == id)) {
        rows.add({
          ...payload,
          'created_at': DateTime.now().toIso8601String(),
          'profiles': authorProfile,
          '_queued': true,
        });
        await _cache.put(uid, 'comments', rows, id: postId);
      }
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> inbox() async {
    const base =
        'id,type,is_read,created_at,post_id,story_id,'
        'profiles!notifications_actor_id_fkey(id,username,display_name,avatar_url),'
        'posts(caption,post_media(media_url,thumbnail_url,media_type,position)),'
        'comments(body)';
    dynamic rows;
    try {
      rows = await _db
          .from('notifications')
          .select('$base,body')
          .eq('recipient_id', userId)
          .order('created_at', ascending: false)
          .limit(80)
          .timeout(const Duration(seconds: 20));
    } on PostgrestException {
      // The inbox SQL migration has not been run yet: load without `body`.
      rows = await _db
          .from('notifications')
          .select(base)
          .eq('recipient_id', userId)
          .order('created_at', ascending: false)
          .limit(80)
          .timeout(const Duration(seconds: 20));
    }
    final list = (rows as List)
        .map((raw) => Map<String, dynamic>.from(raw as Map))
        .toList();

    String thumbPathOf(Map<String, dynamic> row) {
      final post = row['posts'];
      if (post is! Map) return '';
      final media = (post['post_media'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      if (media.isEmpty) return '';
      media.sort(
        (a, b) => (int.tryParse('${a['position']}') ?? 0).compareTo(
          int.tryParse('${b['position']}') ?? 0,
        ),
      );
      final first = media.first;
      final thumb = (first['thumbnail_url'] ?? '').toString().trim();
      if (_isStoragePath(thumb)) return thumb;
      final isVideo = (first['media_type'] ?? '').toString() == 'video';
      final path = (first['media_url'] ?? '').toString().trim();
      return (!isVideo && _isStoragePath(path)) ? path : '';
    }

    final needed = <String>{};
    for (final row in list) {
      final actor = row['profiles'];
      if (actor is Map) {
        final path = (actor['avatar_url'] ?? '').toString().trim();
        if (_isStoragePath(path)) needed.add(path);
      }
      final t = thumbPathOf(row);
      if (t.isNotEmpty) needed.add(t);
    }
    final urls = await _resolvePaths('post-media', needed);

    for (final row in list) {
      final actor = row['profiles'];
      final path = actor is Map
          ? (actor['avatar_url'] ?? '').toString().trim()
          : '';
      row['actor_avatar'] = _isStoragePath(path) ? (urls[path] ?? '') : path;
      final t = thumbPathOf(row);
      row['post_thumb'] = t.isEmpty ? '' : (urls[t] ?? '');
      final comment = row['comments'];
      row['comment_text'] = comment is Map
          ? (comment['body'] ?? '').toString()
          : '';
    }
    return list;
  }

  Future<List<Map<String, dynamic>>> notifications() async {
    final rows = await _db
        .from('notifications')
        .select(
          'id,type,is_read,created_at,profiles!notifications_actor_id_fkey(username,display_name,avatar_url),posts(caption)',
        )
        .eq('recipient_id', userId)
        .order('created_at', ascending: false)
        .limit(50);
    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> myPosts() async {
    final rows = await _db
        .from('posts')
        .select(
          'id,user_id,caption,created_at,post_media(media_url,media_type,position)',
        )
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .limit(100);
    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<int> count(String table, String column, String value) async {
    final rows = await _db.from(table).select(column).eq(column, value);
    return (rows as List).length;
  }

  Future<String> createConversation(String otherUserId) async {
    final session = _db.auth.currentSession;
    if (session == null) {
      throw AuthException('Your session has expired. Please sign in again.');
    }

    // Validate the active access token with Supabase before writing.
    final verified = await _db.auth.getUser();
    final verifiedUser = verified.user;
    if (verifiedUser == null) {
      throw AuthException(
        'Could not verify your account. Please sign in again.',
      );
    }
    final uid = verifiedUser.id;

    if (uid != session.user.id) {
      throw AuthException(
        'Authentication identity mismatch. Please sign out and sign in again.',
      );
    }

    if (otherUserId == uid) {
      throw const FormatException('You cannot message yourself.');
    }

    final existing = await _db
        .from('conversation_members')
        .select('conversation_id')
        .eq('user_id', uid);

    for (final row in (existing as List)) {
      final id = row['conversation_id'].toString();
      final other = await _db
          .from('conversation_members')
          .select('user_id')
          .eq('conversation_id', id)
          .eq('user_id', otherUserId)
          .maybeSingle();
      if (other != null) return id;
    }

    final created = await _db
        .from('conversations')
        .insert({'created_by': uid, 'is_group': false})
        .select('id')
        .single();

    final id = created['id'].toString();

    await _db.from('conversation_members').insert([
      {'conversation_id': id, 'user_id': uid},
      {'conversation_id': id, 'user_id': otherUserId},
    ]);

    return id;
  }

// ---------- Instagram-style conversations ----------

/// Full inbox rows: other participant profile + last message + unread flag.
Future<List<Map<String, dynamic>>> conversationsDetailed() async {
  final uid = userId;

  // 1) Memberships for me
  final memberships = await _db
      .from('conversation_members')
      .select('conversation_id,last_read_at,joined_at')
      .eq('user_id', uid)
      .order('joined_at', ascending: false)
      .timeout(const Duration(seconds: 15));

  final list = (memberships as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  if (list.isEmpty) return [];

  final convIds = list.map((e) => e['conversation_id'].toString()).toList();

  // 2) Other members in those conversations
  final members = await _db
      .from('conversation_members')
      .select('conversation_id,user_id')
      .inFilter('conversation_id', convIds)
      .neq('user_id', uid)
      .timeout(const Duration(seconds: 15));

  final otherByConv = <String, String>{};
  for (final raw in (members as List)) {
    final m = Map<String, dynamic>.from(raw as Map);
    otherByConv[m['conversation_id'].toString()] = m['user_id'].toString();
  }

  final otherIds = otherByConv.values.toSet().toList();
  final profiles = <String, Map<String, dynamic>>{};
  if (otherIds.isNotEmpty) {
    final prows = await _db
        .from('profiles')
        .select('id,username,display_name,avatar_url')
        .inFilter('id', otherIds)
        .timeout(const Duration(seconds: 15));
    for (final raw in (prows as List)) {
      final p = Map<String, dynamic>.from(raw as Map);
      final resolved = await _resolveProfileAvatar(p);
      profiles[resolved['id'].toString()] = resolved;
    }
  }

  // 3) Latest message per conversation (simple approach; good enough for <200 chats)
  final lastByConv = <String, Map<String, dynamic>>{};
  for (final id in convIds) {
    try {
      final rows = await _db
          .from('messages')
          .select('id,body,media_type,sender_id,created_at')
          .eq('conversation_id', id)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 8));
      if ((rows as List).isNotEmpty) {
        lastByConv[id] = Map<String, dynamic>.from(rows.first as Map);
      }
    } catch (_) {}
  }

  final out = <Map<String, dynamic>>[];
  for (final m in list) {
    final cid = m['conversation_id'].toString();
    final otherId = otherByConv[cid] ?? '';
    final profile = profiles[otherId] ?? {};
    final last = lastByConv[cid];
    final lastAt = last == null
        ? null
        : DateTime.tryParse((last['created_at'] ?? '').toString());
    final lastRead = DateTime.tryParse((m['last_read_at'] ?? '').toString());
    final unread = last != null &&
        last['sender_id'] != uid &&
        (lastRead == null ||
            (lastAt != null && lastAt.isAfter(lastRead)));

    out.add({
      'conversation_id': cid,
      'last_read_at': m['last_read_at'],
      'other_user_id': otherId,
      'other_name': (profile['display_name'] ?? profile['username'] ?? 'User')
          .toString(),
      'other_username': (profile['username'] ?? '').toString(),
      'other_avatar': (profile['avatar_url'] ?? '').toString(),
      'last_body': (last?['body'] ?? '').toString(),
      'last_media_type': (last?['media_type'] ?? '').toString(),
      'last_at': lastAt,
      'unread': unread,
    });
  }

  // Sort by last message time (newest first)
  out.sort((a, b) {
    final aa = a['last_at'] as DateTime?;
    final bb = b['last_at'] as DateTime?;
    if (aa == null && bb == null) return 0;
    if (aa == null) return 1;
    if (bb == null) return -1;
    return bb.compareTo(aa);
  });
  return out;
}

Future<List<Map<String, dynamic>>> messagesDetailed(
  String conversationId,
) async {
  final rows = await _db
      .from('messages')
      .select(
        'id,conversation_id,sender_id,body,media_url,media_type,created_at',
      )
      .eq('conversation_id', conversationId)
      .isFilter('deleted_at', null)
      .order('created_at')
      .limit(300)
      .timeout(const Duration(seconds: 20));

  final list = (rows as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  // Conversation-level read receipt based on members' last_read_at.
  final memberRows = await _db
      .from('conversation_members')
      .select('user_id,last_read_at')
      .eq('conversation_id', conversationId);

  final otherMembers = (memberRows as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .where((m) => (m['user_id'] ?? '').toString() != userId)
      .toList();

  for (final message in list) {
    message['read_at'] = null;
    if ((message['sender_id'] ?? '').toString() != userId ||
        otherMembers.isEmpty) {
      continue;
    }
    final created = DateTime.tryParse(
      (message['created_at'] ?? '').toString(),
    );
    if (created == null) continue;

    final everyoneRead = otherMembers.every((member) {
      final value = member['last_read_at'];
      if (value == null) return false;
      final readAt = DateTime.tryParse(value.toString());
      return readAt != null && !readAt.isBefore(created);
    });

    if (everyoneRead) {
      message['read_at'] = created.toIso8601String();
    }
  }

  // Resolve media + attach sender profiles
  final needed = <String>{};
  final senderIds = <String>{};
  final attachmentRows = <Map<String, dynamic>>[];

  for (final m in list) {
    senderIds.add((m['sender_id'] ?? '').toString());
    final path = (m['media_url'] ?? '').toString().trim();
    if (_isStoragePath(path)) needed.add(path);
  }

  if (list.isNotEmpty) {
    final rawAttachments = await _db
        .from('message_attachments')
        .select('id,message_id,conversation_id,sender_id,media_url,media_type,position,created_at')
        .eq('conversation_id', conversationId)
        .inFilter('message_id', list.map((m) => m['id']).toList())
        .order('position');

    attachmentRows.addAll(
      (rawAttachments as List)
          .map((e) => Map<String, dynamic>.from(e as Map)),
    );
    for (final a in attachmentRows) {
      final path = (a['media_url'] ?? '').toString().trim();
      if (_isStoragePath(path)) needed.add(path);
    }
  }

  final urls = await _resolvePaths('chat-media', needed, strict: false);

  final profiles = <String, Map<String, dynamic>>{};
  if (senderIds.isNotEmpty) {
    final prows = await _db
        .from('profiles')
        .select('id,username,display_name,avatar_url')
        .inFilter('id', senderIds.toList());
    for (final raw in (prows as List)) {
      final p = await _resolveProfileAvatar(
        Map<String, dynamic>.from(raw as Map),
      );
      profiles[p['id'].toString()] = p;
    }
  }

  for (final m in list) {
    final path = (m['media_url'] ?? '').toString().trim();
    if (_isStoragePath(path)) {
      m['resolved_media_url'] = urls[path] ?? '';
    } else {
      m['resolved_media_url'] = path;
    }
    m['sender_profile'] = profiles[(m['sender_id'] ?? '').toString()];
  }

  final attachmentsByMessage = <String, List<Map<String, dynamic>>>{};
  for (final a in attachmentRows) {
    final path = (a['media_url'] ?? '').toString().trim();
    a['resolved_media_url'] =
        _isStoragePath(path) ? (urls[path] ?? '') : path;
    final messageId = (a['message_id'] ?? '').toString();
    (attachmentsByMessage[messageId] ??= <Map<String, dynamic>>[]).add(a);
  }
  for (final m in list) {
    m['resolved_attachments'] =
        attachmentsByMessage[(m['id'] ?? '').toString()] ??
        <Map<String, dynamic>>[];
  }
  return list;
}

Future<void> sendMessage(String conversationId, String body) async {
  if (body.trim().isEmpty) return;
  await _db.from('messages').insert({
    'conversation_id': conversationId,
    'sender_id': userId,
    'body': body.trim(),
  });
}

Future<void> sendMediaMessage({
  required String conversationId,
  required File file,
  required String mediaType, // 'image' | 'video'
}) async {
  final ext = p.extension(file.path).toLowerCase();
  final objectPath =
      '$userId/$conversationId/${DateTime.now().millisecondsSinceEpoch}$ext';
  await _db.storage.from('chat-media').upload(
        objectPath,
        file,
        fileOptions: FileOptions(
          contentType: mediaType == 'video'
              ? 'video/mp4'
              : 'image/jpeg',
          upsert: false,
        ),
      );
  await _db.from('messages').insert({
    'conversation_id': conversationId,
    'sender_id': userId,
    'body': '',
    'media_url': objectPath,
    'media_type': mediaType,
  });
}

Future<void> sendMediaAlbum({
  required String conversationId,
  required List<File> files,
}) async {
  if (files.isEmpty || files.length > 10) {
    throw ArgumentError('Choose between 1 and 10 photos.');
  }

  final uploadedPaths = <String>[];
  var parentInserted = false;

  String contentTypeFor(String ext) {
    switch (ext.toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.jpg':
      case '.jpeg':
      default:
        return 'image/jpeg';
    }
  }

  try {
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      var ext = p.extension(file.path).toLowerCase();
      if (!['.jpg', '.jpeg', '.png', '.webp', '.gif'].contains(ext)) {
        throw StateError(
          'Unsupported photo format: ${ext.isEmpty ? '(unknown)' : ext}. '
          'Choose JPG, PNG, WebP, or GIF photos.',
        );
      }

      final objectPath =
          '$userId/$conversationId/${DateTime.now().millisecondsSinceEpoch}_$i$ext';
      await _db.storage.from('chat-media').upload(
        objectPath,
        file,
        fileOptions: FileOptions(
          contentType: contentTypeFor(ext),
          upsert: false,
        ),
      );
      uploadedPaths.add(objectPath);
    }

    final parent = await _db.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': userId,
      'body': '',
      'media_url': uploadedPaths.first,
      'media_type': 'image',
    }).select('id').single();

    parentInserted = true;
    final messageId = parent['id'].toString();

    await _db.from('message_attachments').insert([
      for (var i = 0; i < uploadedPaths.length; i++)
        {
          'conversation_id': conversationId,
          'message_id': messageId,
          'sender_id': userId,
          'media_url': uploadedPaths[i],
          'media_type': 'image',
          'position': i,
        },
    ]);
  } catch (_) {
    // Keep uploads if the parent message exists; it may already reference them.
    if (!parentInserted && uploadedPaths.isNotEmpty) {
      try {
        await _db.storage.from('chat-media').remove(uploadedPaths);
      } catch (_) {
        // Preserve the original send error.
      }
    }
    rethrow;
  }
}

// Keep the original simple helpers for backward compatibility:
Future<List<Map<String, dynamic>>> conversations() async {
  return conversationsDetailed();
}

Future<List<Map<String, dynamic>>> messages(String conversationId) async {
  return messagesDetailed(conversationId);
}
}