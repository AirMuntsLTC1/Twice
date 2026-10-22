import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin, fast network layer for the chat room.
///
/// Differences from the old `messagesDetailed()`:
///  * never signs URLs (media is resolved lazily by [ChatMediaStore])
///  * never loads profiles / read-state on every call
///  * supports "latest page", "only newer than X" and "older than X"
///  * inserts return the saved row, so the UI never has to guess/match
class ChatRepository {
  ChatRepository._();
  static final ChatRepository instance = ChatRepository._();

  static const _cols =
      'id,conversation_id,sender_id,body,media_url,media_type,created_at';
  static const _bucket = 'chat-media';

  SupabaseClient get _db => Supabase.instance.client;
  String get uid => _db.auth.currentUser?.id ?? '';

  List<Map<String, dynamic>> _maps(dynamic rows) => (rows as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  Future<List<Map<String, dynamic>>> latest(
    String conversationId, {
    int limit = 40,
  }) async {
    final rows = await _db
        .from('messages')
        .select(_cols)
        .eq('conversation_id', conversationId)
        .isFilter('deleted_at', null)
        .order('created_at', ascending: false)
        .limit(limit)
        .timeout(const Duration(seconds: 15));
    final list = _maps(rows).reversed.toList();
    return _withAttachments(conversationId, list);
  }

  /// Messages created at/after [since] (ascending). Callers de-duplicate.
  Future<List<Map<String, dynamic>>> after(
    String conversationId,
    DateTime since, {
    int limit = 100,
  }) async {
    final rows = await _db
        .from('messages')
        .select(_cols)
        .eq('conversation_id', conversationId)
        .isFilter('deleted_at', null)
        .gte('created_at', since.toUtc().toIso8601String())
        .order('created_at', ascending: true)
        .limit(limit)
        .timeout(const Duration(seconds: 15));
    return _withAttachments(conversationId, _maps(rows));
  }

  /// A page of history older than [before] (returned ascending).
  Future<List<Map<String, dynamic>>> before(
    String conversationId,
    DateTime before, {
    int limit = 40,
  }) async {
    final rows = await _db
        .from('messages')
        .select(_cols)
        .eq('conversation_id', conversationId)
        .isFilter('deleted_at', null)
        .lt('created_at', before.toUtc().toIso8601String())
        .order('created_at', ascending: false)
        .limit(limit)
        .timeout(const Duration(seconds: 15));
    final list = _maps(rows).reversed.toList();
    return _withAttachments(conversationId, list);
  }

  Future<List<Map<String, dynamic>>> attachmentsFor(
    String conversationId,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return [];
    final rows = await _db
        .from('message_attachments')
        .select('message_id,media_url,media_type,position')
        .eq('conversation_id', conversationId)
        .inFilter('message_id', messageIds)
        .order('position')
        .timeout(const Duration(seconds: 15));
    return _maps(rows);
  }

  Future<List<Map<String, dynamic>>> _withAttachments(
    String conversationId,
    List<Map<String, dynamic>> list,
  ) async {
    final ids = <String>[
      for (final m in list)
        if ((m['media_type'] ?? '').toString() == 'image') m['id'].toString(),
    ];
    if (ids.isEmpty) return list;
    try {
      final atts = await attachmentsFor(conversationId, ids);
      final byMessage = <String, List<Map<String, dynamic>>>{};
      for (final a in atts) {
        (byMessage[(a['message_id'] ?? '').toString()] ??= []).add(a);
      }
      for (final m in list) {
        final found = byMessage[(m['id'] ?? '').toString()];
        if (found != null) m['attachments'] = found;
      }
    } catch (_) {
      // Attachments are an enhancement; the parent row still renders.
    }
    return list;
  }

  /// Oldest "last_read_at" among the other members, or null if anyone has
  /// never read the chat. Used for the blue double-check.
  Future<DateTime?> peerReadUpTo(String conversationId) async {
    final rows = await _db
        .from('conversation_members')
        .select('user_id,last_read_at')
        .eq('conversation_id', conversationId)
        .neq('user_id', uid)
        .timeout(const Duration(seconds: 10));
    final list = _maps(rows);
    if (list.isEmpty) return null;
    DateTime? oldest;
    for (final m in list) {
      final v = m['last_read_at'];
      if (v == null) return null;
      final d = DateTime.tryParse(v.toString());
      if (d == null) return null;
      if (oldest == null || d.isBefore(oldest)) oldest = d;
    }
    return oldest;
  }

  Future<Map<String, dynamic>> sendText(
    String conversationId,
    String body,
  ) async {
    final row = await _db
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': uid,
          'body': body,
        })
        .select(_cols)
        .single()
        .timeout(const Duration(seconds: 20));
    return Map<String, dynamic>.from(row);
  }

  String _contentType(String ext, bool video) {
    if (video) return 'video/mp4';
    switch (ext) {
      case '.gif':
        return 'image/gif';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }

  Future<Map<String, dynamic>> sendMedia({
    required String conversationId,
    required File file,
    required String mediaType,
  }) async {
    final ext = p.extension(file.path).toLowerCase();
    final objectPath =
        '$uid/$conversationId/${DateTime.now().microsecondsSinceEpoch}$ext';
    await _db.storage
        .from(_bucket)
        .upload(
          objectPath,
          file,
          fileOptions: FileOptions(
            contentType: _contentType(ext, mediaType == 'video'),
            upsert: false,
          ),
        )
        .timeout(const Duration(minutes: 5));
    final row = await _db
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': uid,
          'body': '',
          'media_url': objectPath,
          'media_type': mediaType,
        })
        .select(_cols)
        .single()
        .timeout(const Duration(seconds: 20));
    return Map<String, dynamic>.from(row);
  }

  Future<Map<String, dynamic>> sendAlbum({
    required String conversationId,
    required List<File> files,
  }) async {
    if (files.isEmpty || files.length > 10) {
      throw ArgumentError('Choose between 1 and 10 photos.');
    }
    final uploaded = <String>[];
    var parentInserted = false;
    try {
      for (var i = 0; i < files.length; i++) {
        final ext = p.extension(files[i].path).toLowerCase();
        if (!['.jpg', '.jpeg', '.png', '.webp', '.gif'].contains(ext)) {
          throw StateError(
            'Unsupported photo format: ${ext.isEmpty ? '(unknown)' : ext}.',
          );
        }
        final objectPath =
            '$uid/$conversationId/${DateTime.now().microsecondsSinceEpoch}_$i$ext';
        await _db.storage
            .from(_bucket)
            .upload(
              objectPath,
              files[i],
              fileOptions: FileOptions(
                contentType: _contentType(ext, false),
                upsert: false,
              ),
            )
            .timeout(const Duration(minutes: 5));
        uploaded.add(objectPath);
      }

      final parent = await _db
          .from('messages')
          .insert({
            'conversation_id': conversationId,
            'sender_id': uid,
            'body': '',
            'media_url': uploaded.first,
            'media_type': 'image',
          })
          .select(_cols)
          .single()
          .timeout(const Duration(seconds: 20));
      parentInserted = true;
      final row = Map<String, dynamic>.from(parent);
      final messageId = row['id'].toString();

      final atts = <Map<String, dynamic>>[
        for (var i = 0; i < uploaded.length; i++)
          {
            'conversation_id': conversationId,
            'message_id': messageId,
            'sender_id': uid,
            'media_url': uploaded[i],
            'media_type': 'image',
            'position': i,
          },
      ];
      await _db.from('message_attachments').insert(atts);
      row['attachments'] = [
        for (final a in atts)
          {
            'message_id': messageId,
            'media_url': a['media_url'],
            'media_type': 'image',
            'position': a['position'],
          },
      ];
      return row;
    } catch (_) {
      if (!parentInserted && uploaded.isNotEmpty) {
        try {
          await _db.storage.from(_bucket).remove(uploaded);
        } catch (_) {}
      }
      rethrow;
    }
  }
}
