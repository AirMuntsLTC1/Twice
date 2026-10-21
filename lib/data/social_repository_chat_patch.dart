// =============================================================================
// PATCH: append / replace the conversation methods in lib/data/social_repository.dart
// Copy the methods below into SocialRepository (replace existing conversations /
// messages / sendMessage and add the new ones).
// =============================================================================

/*
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

    // Resolve media + attach sender profiles
    final needed = <String>{};
    final senderIds = <String>{};
    for (final m in list) {
      senderIds.add((m['sender_id'] ?? '').toString());
      final path = (m['media_url'] ?? '').toString().trim();
      if (_isStoragePath(path)) needed.add(path);
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

  // Keep the original simple helpers for backward compatibility:
  Future<List<Map<String, dynamic>>> conversations() async {
    return conversationsDetailed();
  }

  Future<List<Map<String, dynamic>>> messages(String conversationId) async {
    return messagesDetailed(conversationId);
  }
*/

// Also ensure these imports exist at the top of social_repository.dart:
// import 'dart:io';
// import 'package:path/path.dart' as p;
