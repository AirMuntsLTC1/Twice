import 'dart:async';
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
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>?> cachedMyProfile() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    final value = await _cache.get(uid, 'profile');
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<Map<String, dynamic>> _resolveProfileAvatar(
    Map<String, dynamic> row,
  ) async {
    final path = (row['avatar_url'] ?? '').toString().trim();
    if (path.isEmpty || path.startsWith('http')) return row;
    try {
      final local = await OfflineMediaCache.instance.existingUri('post-media', path);
      if (local != null) {
        row['avatar_url'] = local;
      } else {
        final signed = await _db.storage
            .from('post-media')
            .createSignedUrl(path, 3600);
        row['avatar_url'] = signed;
        unawaited(_warmAvatarCache(row, path, signed).catchError((Object _) {}));
      }
    } catch (_) {
      // Keep the stored path if storage cannot resolve it.
    }
    return row;
  }

  Future<void> _warmAvatarCache(
    Map<String, dynamic> profile,
    String objectPath,
    String signedUrl,
  ) async {
    final local = await OfflineMediaCache.instance.cacheFromUrl(
      bucket: 'post-media',
      objectPath: objectPath,
      signedUrl: signedUrl,
      isVideo: false,
    );
    if (local == null) return;
    final uid = _db.auth.currentUser?.id;
    final profileId = profile['id']?.toString();
    if (uid == null || profileId == null) return;
    if (profileId == uid) {
      final cachedProfile = await _cache.get(uid, 'profile');
      if (cachedProfile is Map &&
          cachedProfile['avatar_url']?.toString() == signedUrl) {
        cachedProfile['avatar_url'] = local;
        await _cache.put(uid, 'profile', cachedProfile);
      }
    }
    final cachedFeed = await _cache.get(uid, 'feed');
    if (cachedFeed is List) {
      for (final rawPost in cachedFeed) {
        if (rawPost is! Map) continue;
        final author = rawPost['profiles'];
        if (author is Map &&
            author['id']?.toString() == profileId &&
            author['avatar_url']?.toString() == signedUrl) {
          author['avatar_url'] = local;
        }
      }
      await _cache.put(uid, 'feed', cachedFeed);
    }
  }

  Future<Map<String, dynamic>> ensureProfile() async {
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
    await ensureProfile();
    final row = await _db.from('profiles').select().eq('id', userId).single();
    final resolved = await _resolveProfileAvatar(
      Map<String, dynamic>.from(row),
    );
    await _cache.put(userId, 'profile', resolved);
    return resolved;
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
    await ensureProfile();
    final rows = await _db
        .from('posts')
        .select(
          'id,user_id,caption,visibility,comments_enabled,created_at,profiles!posts_user_id_fkey(id,username,display_name,avatar_url),post_media(id,media_url,thumbnail_url,media_type,position),post_likes(user_id),saved_posts(user_id)',
        )
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    final resolved = await Future.wait(
      (rows as List).map((raw) async {
        final post = Map<String, dynamic>.from(raw as Map);
        final authorRaw = post['profiles'];
        if (authorRaw is Map) {
          post['profiles'] = await _resolveProfileAvatar(
            Map<String, dynamic>.from(authorRaw),
          );
        }
        post['media_resolved'] = await _resolveMedia(
          post['post_media'] as List? ?? const [],
          'post-media',
        );
        return post;
      }),
    );
    await _cache.put(userId, 'feed', resolved);
    // Do not block first paint on media downloads. Successfully downloaded
    // media paths are persisted into this feed cache for the next offline launch.
    unawaited(_warmFeedMediaCache(resolved).catchError((Object _) {}));
    return resolved;
  }

  Future<void> _warmFeedMediaCache(List<Map<String, dynamic>> feedRows) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    var warmed = 0;
    for (final post in feedRows) {
      final media = (post['media_resolved'] as List? ?? const []);
      for (final raw in media) {
        if (warmed >= 12) return; // Bound background data usage per refresh.
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final objectPath = (item['media_url'] ?? '').toString().trim();
        final url = (item['resolved_url'] ?? '').toString().trim();
        if (objectPath.isEmpty || url.isEmpty || url.startsWith('file://')) {
          continue;
        }
        warmed++;
        final type = (item['media_type'] ?? '').toString().toLowerCase();
        final local = await OfflineMediaCache.instance.cacheFromUrl(
          bucket: 'post-media',
          objectPath: objectPath,
          signedUrl: url,
          isVideo: type == 'video',
        );
        if (local == null) continue;
        item['resolved_url'] = local;
        final thumbnailPath = (item['thumbnail_url'] ?? '').toString().trim();
        final thumbnailUrl =
            (item['resolved_thumbnail_url'] ?? '').toString().trim();
        if (thumbnailPath.isNotEmpty &&
            thumbnailUrl.isNotEmpty &&
            !thumbnailUrl.startsWith('file://')) {
          final localThumb = await OfflineMediaCache.instance.cacheFromUrl(
            bucket: 'post-media',
            objectPath: thumbnailPath,
            signedUrl: thumbnailUrl,
            isVideo: false,
          );
          if (localThumb != null) item['resolved_thumbnail_url'] = localThumb;
        }
        final liveMedia = (post['media_resolved'] as List? ?? const []);
        for (var i = 0; i < liveMedia.length; i++) {
          if (liveMedia[i] is Map &&
              liveMedia[i]['media_url']?.toString() == objectPath) {
            liveMedia[i]['resolved_url'] = local;
            if (item['resolved_thumbnail_url']?.toString().startsWith('file://') ==
                true) {
              liveMedia[i]['resolved_thumbnail_url'] =
                  item['resolved_thumbnail_url'];
            }
          }
        }
        final cached = await _cache.get(uid, 'feed');
        if (cached is List) {
          for (final cachedRaw in cached) {
            if (cachedRaw is! Map) continue;
            if (cachedRaw['id']?.toString() != post['id']?.toString()) {
              continue;
            }
            final cachedMedia = (cachedRaw['media_resolved'] as List? ?? const []);
            for (final cachedItem in cachedMedia) {
              if (cachedItem is Map &&
                  cachedItem['media_url']?.toString() == objectPath) {
                cachedItem['resolved_url'] = local;
                if (item['resolved_thumbnail_url']?.toString().startsWith('file://') ==
                    true) {
                  cachedItem['resolved_thumbnail_url'] =
                      item['resolved_thumbnail_url'];
                }
              }
            }
          }
          await _cache.put(uid, 'feed', cached);
        }
      }
    }
  }

  Future<List<Map<String, dynamic>>> _resolveMedia(
    List rows,
    String bucket,
  ) async {
    final result = <Map<String, dynamic>>[];
    for (final raw in rows) {
      final item = Map<String, dynamic>.from(raw as Map);
      final path = (item['media_url'] ?? '').toString().trim();
      try {
        final local = path.isEmpty || path.startsWith('http')
            ? null
            : await OfflineMediaCache.instance.existingUri(bucket, path);
        item['resolved_url'] = local ??
            (path.startsWith('http')
                ? path
                : await _db.storage.from(bucket).createSignedUrl(path, 3600));
      } catch (_) {
        item['resolved_url'] = '';
      }

      final thumbnailPath = (item['thumbnail_url'] ?? '').toString().trim();
      if (thumbnailPath.isNotEmpty) {
        try {
          final localThumb = thumbnailPath.startsWith('http')
              ? null
              : await OfflineMediaCache.instance.existingUri(bucket, thumbnailPath);
          item['resolved_thumbnail_url'] = localThumb ??
              (thumbnailPath.startsWith('http')
                  ? thumbnailPath
                  : await _db.storage
                      .from(bucket)
                      .createSignedUrl(thumbnailPath, 3600));
        } catch (_) {
          item['resolved_thumbnail_url'] = '';
        }
      } else {
        item['resolved_thumbnail_url'] = '';
      }
      result.add(item);
    }
    return result;
  }

  bool _looksLikeNetworkFailure(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('socketexception') ||
        text.contains('failed host lookup') ||
        text.contains('clientexception') ||
        text.contains('connection reset') ||
        text.contains('connection refused') ||
        text.contains('network is unreachable') ||
        text.contains('connection closed') ||
        text.contains('timed out') ||
        text.contains('timeout') ||
        text.contains('no address associated with hostname');
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

  /// Replays queued likes and comments for the signed-in account.
  Future<void> syncPendingLikes() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;

    final pending = await _cache.pending(uid);
    for (final item in pending) {
      if (item['operation'] != 'set_like' &&
          item['operation'] != 'add_comment') {
        continue;
      }
      try {
        final payload = Map<String, dynamic>.from(item['payload'] as Map);
        if (item['operation'] == 'add_comment') {
          await _db.from('comments').upsert(
            payload,
            onConflict: 'id',
            ignoreDuplicates: true,
          ).timeout(const Duration(seconds: 15));
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
    if (saved) {
      await _db
          .from('saved_posts')
          .delete()
          .eq('post_id', postId)
          .eq('user_id', userId);
    } else {
      await _db
          .from('saved_posts')
          .upsert(
            {'post_id': postId, 'user_id': userId},
            onConflict: 'user_id,post_id',
            ignoreDuplicates: true,
          );
    }
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
    final rows = await _db
        .from('stories')
        .select('id,user_id,media_url,media_type,caption,created_at,expires_at')
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at', ascending: true);

    final stories = (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();

    if (stories.isEmpty) return stories;

    final ids = stories
        .map((story) => story['user_id'].toString())
        .toSet()
        .toList();

    final profiles = await _db
        .from('profiles')
        .select('id,username,display_name,avatar_url')
        .inFilter('id', ids);

    final byId = <String, Map<String, dynamic>>{};
    for (final raw in profiles as List) {
      final profile = await _resolveProfileAvatar(
        Map<String, dynamic>.from(raw as Map),
      );
      byId[profile['id'].toString()] = profile;
    }

    for (final story in stories) {
      story['profiles'] = byId[story['user_id'].toString()] ?? {};
      final path = (story['media_url'] ?? '').toString();
      try {
        story['resolved_url'] = path.startsWith('http')
            ? path
            : await _db.storage.from('stories').createSignedUrl(path, 3600);
      } catch (_) {
        story['resolved_url'] = '';
      }
    }

    return stories;
  }

  Future<void> publishStory(AssetEntity asset, String caption) async {
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
      final result = (rows as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
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
    final value = await _cache.get(userId, 'comments', id: postId);
    if (value is! List) return [];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
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
  Future<bool> addComment(String postId, String body, {String? commentId}) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw AuthException('Please sign in again.');
    final text = body.trim();
    if (text.isEmpty) return true;
    final id = commentId ?? _newCommentId();
    final payload = <String, dynamic>{
      'id': id,
      'post_id': postId,
      'user_id': uid,
      'body': text,
    };
    try {
      await _db.from('comments').insert(payload).timeout(
        const Duration(seconds: 15),
      );
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
          'profiles': const {'display_name': 'You'},
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
          'profiles': const {'display_name': 'You'},
          '_queued': true,
        });
        await _cache.put(uid, 'comments', rows, id: postId);
      }
      return false;
    }
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
    if (otherUserId == userId) {
      throw const FormatException('You cannot message yourself.');
    }
    final existing = await _db
        .from('conversation_members')
        .select('conversation_id')
        .eq('user_id', userId);
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
        .insert({'created_by': userId, 'is_group': false})
        .select('id')
        .single();
    final id = created['id'].toString();
    await _db.from('conversation_members').insert([
      {'conversation_id': id, 'user_id': userId},
      {'conversation_id': id, 'user_id': otherUserId},
    ]);
    return id;
  }

  Future<List<Map<String, dynamic>>> conversations() async {
    final rows = await _db
        .from('conversation_members')
        .select(
          'conversation_id,last_read_at,conversations(id,title,is_group,created_at)',
        )
        .eq('user_id', userId)
        .order('joined_at', ascending: false);
    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> messages(String conversationId) async {
    final rows = await _db
        .from('messages')
        .select(
          'id,conversation_id,sender_id,body,media_url,media_type,created_at',
        )
        .eq('conversation_id', conversationId)
        .isFilter('deleted_at', null)
        .order('created_at')
        .limit(200);
    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> sendMessage(String conversationId, String body) async {
    if (body.trim().isEmpty) return;
    await _db.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': userId,
      'body': body.trim(),
    });
  }
}
