import 'package:photo_manager/photo_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase data boundary for Twice. UI widgets should call this repository
/// rather than issuing database requests directly.
class SocialRepository {
  SocialRepository._();
  static final SocialRepository instance = SocialRepository._();
  SupabaseClient get _db => Supabase.instance.client;
  String get userId => _db.auth.currentUser!.id;

  Future<Map<String, dynamic>> _resolveProfileAvatar(
    Map<String, dynamic> row,
  ) async {
    final path = (row['avatar_url'] ?? '').toString().trim();
    if (path.isEmpty || path.startsWith('http')) return row;
    try {
      row['avatar_url'] = await _db.storage
          .from('post-media')
          .createSignedUrl(path, 3600);
    } catch (_) {
      // Keep the stored path if storage cannot resolve it.
    }
    return row;
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
    return await _resolveProfileAvatar(Map<String, dynamic>.from(row));
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
    }

    await _db.from('profiles').update(values).eq('id', userId);
  }

  Future<List<Map<String, dynamic>>> feed({
    int limit = 30,
    int offset = 0,
  }) async {
    await ensureProfile();
    final rows = await _db
        .from('posts')
        .select(
          'id,user_id,caption,visibility,comments_enabled,created_at,profiles!posts_user_id_fkey(id,username,display_name,avatar_url),post_media(id,media_url,media_type,position),post_likes(user_id),saved_posts(user_id)',
        )
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return Future.wait(
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
  }

  Future<List<Map<String, dynamic>>> _resolveMedia(
    List rows,
    String bucket,
  ) async {
    final result = <Map<String, dynamic>>[];
    for (final raw in rows) {
      final item = Map<String, dynamic>.from(raw as Map);
      final path = (item['media_url'] ?? '').toString();
      try {
        item['resolved_url'] = path.startsWith('http')
            ? path
            : await _db.storage.from(bucket).createSignedUrl(path, 3600);
      } catch (_) {
        item['resolved_url'] = '';
      }
      result.add(item);
    }
    return result;
  }

  Future<void> toggleLike(String postId, bool currentlyLiked) async {
    if (currentlyLiked) {
      await _db
          .from('post_likes')
          .delete()
          .eq('post_id', postId)
          .eq('user_id', userId);
    } else {
      await _db
          .from('post_likes')
          .upsert(
            {'post_id': postId, 'user_id': userId},
            onConflict: 'post_id,user_id',
            ignoreDuplicates: true,
          );
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
        await _db.from('post_media').insert({
          'post_id': postId,
          'media_url': objectPath,
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

  String _mime(String ext) => switch (ext) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'mp4' => 'video/mp4',
    'webm' => 'video/webm',
    'heic' => 'image/heic',
    _ => 'image/jpeg',
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

  Future<bool> isFollowing(String profileId) async =>
      await _db
          .from('follows')
          .select('follower_id')
          .eq('follower_id', userId)
          .eq('following_id', profileId)
          .maybeSingle() !=
      null;
  Future<void> follow(String profileId, {required bool privateAccount}) async {
    await _db.from('follows').upsert({
      'follower_id': userId,
      'following_id': profileId,
      'status': privateAccount ? 'pending' : 'accepted',
    }, onConflict: 'follower_id,following_id');
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
        .select('id,display_name,username,avatar_url')
        .inFilter('id', ids)
        .order('display_name');

    final profiles = (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();

    return Future.wait(profiles.map(_resolveProfileAvatar));
  }

  Future<List<Map<String, dynamic>>> comments(String postId) async {
    final rows = await _db
        .from('comments')
        .select(
          'id,post_id,user_id,parent_id,body,created_at,profiles(username,display_name,avatar_url)',
        )
        .eq('post_id', postId)
        .order('created_at');
    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> addComment(String postId, String body) async {
    if (body.trim().isEmpty) return;
    await _db.from('comments').insert({
      'post_id': postId,
      'user_id': userId,
      'body': body.trim(),
    });
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
