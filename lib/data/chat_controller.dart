import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_cache.dart';
import 'social_repository.dart';
import 'inbox_controller.dart';

enum ChatSendStatus { sending, sent, failed }

/// Immutable-ish chat row used by the UI. Keeps a stable [clientId] so
/// optimistic bubbles do not flicker when the server id arrives.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.clientId,
    required this.conversationId,
    required this.senderId,
    required this.body,
    required this.createdAt,
    this.mediaUrl,
    this.mediaType,
    this.resolvedMediaUrl,
    this.resolvedAttachments = const [],
    this.senderProfile,
    this.status = ChatSendStatus.sent,
    this.readAt,
    this.localFilePath,
  });

  final String id;
  final String clientId;
  final String conversationId;
  final String senderId;
  final String body;
  final DateTime createdAt;
  final String? mediaUrl;
  final String? mediaType;
  final String? resolvedMediaUrl;
  final List<Map<String, dynamic>> resolvedAttachments;
  final Map<String, dynamic>? senderProfile;
  final ChatSendStatus status;
  final DateTime? readAt;
  /// Local file path used while a media message is still uploading.
  final String? localFilePath;

  bool get isMine {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    return uid != null && senderId == uid;
  }

  bool get isLocal => id.startsWith('local-') || status == ChatSendStatus.sending;

  ChatMessage copyWith({
    String? id,
    String? clientId,
    String? body,
    DateTime? createdAt,
    String? mediaUrl,
    String? mediaType,
    String? resolvedMediaUrl,
    List<Map<String, dynamic>>? resolvedAttachments,
    Map<String, dynamic>? senderProfile,
    ChatSendStatus? status,
    DateTime? readAt,
    String? localFilePath,
    bool clearLocalFile = false,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      clientId: clientId ?? this.clientId,
      conversationId: conversationId,
      senderId: senderId,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      mediaType: mediaType ?? this.mediaType,
      resolvedMediaUrl: resolvedMediaUrl ?? this.resolvedMediaUrl,
      resolvedAttachments: resolvedAttachments ?? this.resolvedAttachments,
      senderProfile: senderProfile ?? this.senderProfile,
      status: status ?? this.status,
      readAt: readAt ?? this.readAt,
      localFilePath: clearLocalFile ? null : (localFilePath ?? this.localFilePath),
    );
  }

  Map<String, dynamic> toCacheMap() => {
        'id': id,
        'client_id': clientId,
        'conversation_id': conversationId,
        'sender_id': senderId,
        'body': body,
        'created_at': createdAt.toIso8601String(),
        'media_url': mediaUrl,
        'media_type': mediaType,
        'resolved_media_url': resolvedMediaUrl,
        'resolved_attachments': resolvedAttachments,
        'sender_profile': senderProfile,
        'status': status.name,
        'read_at': readAt?.toIso8601String(),
        'local_file_path': localFilePath,
      };

  static ChatMessage fromServerMap(Map<String, dynamic> m) {
    final id = (m['id'] ?? '').toString();
    final created = DateTime.tryParse((m['created_at'] ?? '').toString()) ??
        DateTime.now().toUtc();
    final readRaw = m['read_at'];
    return ChatMessage(
      id: id,
      clientId: (m['_ui_id'] ?? m['client_id'] ?? id).toString(),
      conversationId: (m['conversation_id'] ?? '').toString(),
      senderId: (m['sender_id'] ?? '').toString(),
      body: (m['body'] ?? '').toString(),
      createdAt: created,
      mediaUrl: m['media_url']?.toString(),
      mediaType: m['media_type']?.toString(),
      resolvedMediaUrl: (m['resolved_media_url'] ?? m['resolved_url'] ?? '')
              .toString()
              .isEmpty
          ? null
          : (m['resolved_media_url'] ?? m['resolved_url']).toString(),
      resolvedAttachments: ((m['resolved_attachments'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      senderProfile: m['sender_profile'] is Map
          ? Map<String, dynamic>.from(m['sender_profile'] as Map)
          : null,
      status: ChatSendStatus.sent,
      readAt: readRaw == null
          ? null
          : DateTime.tryParse(readRaw.toString()),
    );
  }

  static ChatMessage? fromCacheMap(Map<String, dynamic> m) {
    final id = (m['id'] ?? '').toString();
    if (id.isEmpty) return null;
    final created = DateTime.tryParse((m['created_at'] ?? '').toString()) ??
        DateTime.now().toUtc();
    ChatSendStatus status = ChatSendStatus.sent;
    final s = (m['status'] ?? '').toString();
    if (s == 'sending') status = ChatSendStatus.sending;
    if (s == 'failed') status = ChatSendStatus.failed;
    // Never restore "sending" across app restarts — mark failed so user can retry.
    if (status == ChatSendStatus.sending) status = ChatSendStatus.failed;
    return ChatMessage(
      id: id,
      clientId: (m['client_id'] ?? id).toString(),
      conversationId: (m['conversation_id'] ?? '').toString(),
      senderId: (m['sender_id'] ?? '').toString(),
      body: (m['body'] ?? '').toString(),
      createdAt: created,
      mediaUrl: m['media_url']?.toString(),
      mediaType: m['media_type']?.toString(),
      resolvedMediaUrl: m['resolved_media_url']?.toString(),
      resolvedAttachments: ((m['resolved_attachments'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      senderProfile: m['sender_profile'] is Map
          ? Map<String, dynamic>.from(m['sender_profile'] as Map)
          : null,
      status: status,
      readAt: m['read_at'] == null
          ? null
          : DateTime.tryParse(m['read_at'].toString()),
      localFilePath: m['local_file_path']?.toString(),
    );
  }
}

/// Professional chat state for one conversation.
/// - Offline-first cache
/// - Optimistic sends
/// - Incremental realtime (no full list reload on every message)
/// - Stable client ids so bubbles do not jump
class ChatController extends ChangeNotifier {
  ChatController(this.conversationId);

  final String conversationId;

  final List<ChatMessage> _messages = [];
  bool loading = true;
  bool sending = false;
  String? error;
  RealtimeChannel? _channel;
  bool _disposed = false;
  bool _initialLoaded = false;

  /// Other participant online (Realtime Presence).
  bool otherOnline = false;
  String? otherUserId;
  DateTime? otherLastSeen;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  String get _uid => Supabase.instance.client.auth.currentUser?.id ?? '';
  String get _cacheKey => 'chat_msgs_$conversationId';

  Future<void> start({String? peerUserId}) async {
    otherUserId = peerUserId;
    await _loadFromCache();
    await load(initial: true);
    _subscribe();
    _trackPresence();
  }

  Future<void> _loadFromCache() async {
    if (_uid.isEmpty) return;
    try {
      final raw = await LocalCache.instance.get(_uid, _cacheKey);
      if (raw is! List) return;
      final parsed = <ChatMessage>[];
      for (final item in raw) {
        if (item is Map) {
          final m = ChatMessage.fromCacheMap(Map<String, dynamic>.from(item));
          if (m != null) parsed.add(m);
        }
      }
      parsed.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (parsed.isEmpty) return;
      _messages
        ..clear()
        ..addAll(parsed);
      loading = false;
      _initialLoaded = true;
      _safeNotify();
    } catch (e) {
      debugPrint('Chat cache load failed: $e');
    }
  }

  Future<void> _persistCache() async {
    if (_uid.isEmpty) return;
    try {
      final slice = _messages.length > 200
          ? _messages.sublist(_messages.length - 200)
          : _messages;
      await LocalCache.instance.put(
        _uid,
        _cacheKey,
        slice.map((m) => m.toCacheMap()).toList(),
      );
    } catch (e) {
      debugPrint('Chat cache write failed: $e');
    }
  }

  Future<void> load({bool initial = false}) async {
    if (initial && !_initialLoaded) {
      loading = true;
      error = null;
      _safeNotify();
    }
    try {
      final rows =
          await SocialRepository.instance.messagesDetailed(conversationId);
      final server = rows.map(ChatMessage.fromServerMap).toList();
      server.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      // Merge: keep local pending/failed that are not yet on server.
      final merged = <ChatMessage>[];
      final serverIds = server.map((m) => m.id).toSet();
      final matchedClientIds = <String>{};

      for (final s in server) {
        // Prefer existing clientId if we had an optimistic row for this body/time.
        ChatMessage? localMatch;
        for (final local in _messages) {
          if (local.isLocal &&
              local.senderId == s.senderId &&
              local.body == s.body &&
              local.createdAt.difference(s.createdAt).inSeconds.abs() < 120) {
            localMatch = local;
            break;
          }
        }
        if (localMatch != null) {
          matchedClientIds.add(localMatch.clientId);
          merged.add(s.copyWith(clientId: localMatch.clientId));
        } else {
          merged.add(s);
        }
      }

      for (final local in _messages) {
        if (!local.isLocal) continue;
        if (matchedClientIds.contains(local.clientId)) continue;
        if (serverIds.contains(local.id)) continue;
        merged.add(local);
      }

      merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _messages
        ..clear()
        ..addAll(merged);
      loading = false;
      error = null;
      _initialLoaded = true;
      _safeNotify();
      unawaited(_persistCache());
      unawaited(
        InboxController.instance.markConversationRead(conversationId),
      );
    } catch (e) {
      if (_messages.isEmpty) {
        error = e.toString();
      }
      loading = false;
      _safeNotify();
    }
  }

  void _subscribe() {
    final client = Supabase.instance.client;
    _channel = client
        .channel('chat-live-$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (payload) {
            final row = Map<String, dynamic>.from(payload.newRecord);
            unawaited(_onServerInsert(row));
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_attachments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (_) {
            // Attachments rarely need a full reload — soft refresh once.
            unawaited(load(initial: false));
          },
        )
        .subscribe();
  }

  Future<void> _onServerInsert(Map<String, dynamic> row) async {
    final id = (row['id'] ?? '').toString();
    if (id.isEmpty) return;
    if (_messages.any((m) => m.id == id)) return;

    final body = (row['body'] ?? '').toString();
    final senderId = (row['sender_id'] ?? '').toString();
    final created = DateTime.tryParse((row['created_at'] ?? '').toString()) ??
        DateTime.now().toUtc();

    // Match optimistic local bubble.
    final localIndex = _messages.indexWhere(
      (m) =>
          m.isLocal &&
          m.senderId == senderId &&
          m.body == body &&
          m.createdAt.difference(created).inSeconds.abs() < 180,
    );

    if (localIndex >= 0) {
      final local = _messages[localIndex];
      _messages[localIndex] = ChatMessage.fromServerMap({
        ...row,
        '_ui_id': local.clientId,
        'resolved_media_url': local.resolvedMediaUrl ?? local.localFilePath,
        'resolved_attachments': local.resolvedAttachments,
        'sender_profile': local.senderProfile,
      }).copyWith(clientId: local.clientId, status: ChatSendStatus.sent);
      _safeNotify();
      unawaited(_persistCache());
      return;
    }

    // Foreign message (or media we did not optimistically track) — fetch resolved row.
    try {
      final detailed =
          await SocialRepository.instance.messagesDetailed(conversationId);
      final match = detailed.cast<Map<String, dynamic>?>().firstWhere(
            (m) => (m?['id'] ?? '').toString() == id,
            orElse: () => null,
          );
      final msg = ChatMessage.fromServerMap(match ?? row);
      if (_messages.any((m) => m.id == msg.id)) return;
      _messages.add(msg);
      _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _safeNotify();
      unawaited(_persistCache());
      unawaited(
        InboxController.instance.markConversationRead(conversationId),
      );
    } catch (_) {
      final msg = ChatMessage.fromServerMap(row);
      if (_messages.any((m) => m.id == msg.id)) return;
      _messages.add(msg);
      _safeNotify();
    }
  }

  Future<void> sendText(String body) async {
    final text = body.trim();
    if (text.isEmpty || _uid.isEmpty) return;

    final now = DateTime.now().toUtc();
    final clientId = 'local-${now.microsecondsSinceEpoch}';
    final optimistic = ChatMessage(
      id: clientId,
      clientId: clientId,
      conversationId: conversationId,
      senderId: _uid,
      body: text,
      createdAt: now,
      status: ChatSendStatus.sending,
    );

    _messages.add(optimistic);
    sending = true;
    _safeNotify();

    try {
      await SocialRepository.instance.sendMessage(conversationId, text);
      // Realtime or a soft confirm will flip status; do a lightweight confirm.
      final idx = _messages.indexWhere((m) => m.clientId == clientId);
      if (idx >= 0 && _messages[idx].status == ChatSendStatus.sending) {
        // Leave as sending until realtime confirms — or mark sent after short delay.
        Future<void>.delayed(const Duration(milliseconds: 900), () {
          if (_disposed) return;
          final i = _messages.indexWhere((m) => m.clientId == clientId);
          if (i >= 0 && _messages[i].status == ChatSendStatus.sending) {
            _messages[i] = _messages[i].copyWith(status: ChatSendStatus.sent);
            _safeNotify();
            unawaited(_persistCache());
          }
        });
      }
    } catch (e) {
      final idx = _messages.indexWhere((m) => m.clientId == clientId);
      if (idx >= 0) {
        _messages[idx] =
            _messages[idx].copyWith(status: ChatSendStatus.failed);
      }
      _safeNotify();
      rethrow;
    } finally {
      sending = false;
      _safeNotify();
      unawaited(_persistCache());
    }
  }

  Future<void> sendMediaFile({
    required File file,
    required String mediaType,
  }) async {
    if (_uid.isEmpty) return;
    final now = DateTime.now().toUtc();
    final clientId = 'local-media-${now.microsecondsSinceEpoch}';
    final optimistic = ChatMessage(
      id: clientId,
      clientId: clientId,
      conversationId: conversationId,
      senderId: _uid,
      body: '',
      createdAt: now,
      mediaType: mediaType,
      localFilePath: file.path,
      resolvedMediaUrl: 'file://${file.path}',
      status: ChatSendStatus.sending,
    );
    _messages.add(optimistic);
    sending = true;
    _safeNotify();

    try {
      await SocialRepository.instance.sendMediaMessage(
        conversationId: conversationId,
        file: file,
        mediaType: mediaType,
      );
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (_disposed) return;
        final i = _messages.indexWhere((m) => m.clientId == clientId);
        if (i >= 0 && _messages[i].status == ChatSendStatus.sending) {
          _messages[i] = _messages[i].copyWith(status: ChatSendStatus.sent);
          _safeNotify();
        }
      });
      // Soft background sync to attach server media URLs.
      unawaited(Future<void>.delayed(const Duration(seconds: 1), () => load()));
    } catch (e) {
      final idx = _messages.indexWhere((m) => m.clientId == clientId);
      if (idx >= 0) {
        _messages[idx] =
            _messages[idx].copyWith(status: ChatSendStatus.failed);
      }
      _safeNotify();
      rethrow;
    } finally {
      sending = false;
      _safeNotify();
      unawaited(_persistCache());
    }
  }

  Future<void> sendMediaAlbum(List<File> files) async {
    if (files.isEmpty || _uid.isEmpty) return;
    final now = DateTime.now().toUtc();
    final clientId = 'local-album-${now.microsecondsSinceEpoch}';
    final attachments = <Map<String, dynamic>>[];
    for (var i = 0; i < files.length; i++) {
      attachments.add({
        'position': i,
        'media_type': 'image',
        'resolved_media_url': 'file://${files[i].path}',
        'local_file_path': files[i].path,
      });
    }
    final optimistic = ChatMessage(
      id: clientId,
      clientId: clientId,
      conversationId: conversationId,
      senderId: _uid,
      body: '',
      createdAt: now,
      mediaType: 'album',
      resolvedAttachments: attachments,
      status: ChatSendStatus.sending,
    );
    _messages.add(optimistic);
    sending = true;
    _safeNotify();

    try {
      await SocialRepository.instance.sendMediaAlbum(
        conversationId: conversationId,
        files: files,
      );
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (_disposed) return;
        final i = _messages.indexWhere((m) => m.clientId == clientId);
        if (i >= 0 && _messages[i].status == ChatSendStatus.sending) {
          _messages[i] = _messages[i].copyWith(status: ChatSendStatus.sent);
          _safeNotify();
        }
      });
      unawaited(Future<void>.delayed(const Duration(seconds: 1), () => load()));
    } catch (e) {
      final idx = _messages.indexWhere((m) => m.clientId == clientId);
      if (idx >= 0) {
        _messages[idx] =
            _messages[idx].copyWith(status: ChatSendStatus.failed);
      }
      _safeNotify();
      rethrow;
    } finally {
      sending = false;
      _safeNotify();
      unawaited(_persistCache());
    }
  }

  Future<void> retry(ChatMessage failed) async {
    if (failed.status != ChatSendStatus.failed) return;
    // Remove failed bubble and re-send.
    _messages.removeWhere((m) => m.clientId == failed.clientId);
    _safeNotify();
    if ((failed.mediaType == 'image' || failed.mediaType == 'video') &&
        failed.localFilePath != null) {
      await sendMediaFile(
        file: File(failed.localFilePath!),
        mediaType: failed.mediaType!,
      );
    } else if (failed.body.trim().isNotEmpty) {
      await sendText(failed.body);
    }
  }

  RealtimeChannel? _presence;

  void _trackPresence() {
    if (otherUserId == null || otherUserId!.isEmpty || _uid.isEmpty) return;
    try {
      final client = Supabase.instance.client;
      final channel = client.channel('presence-dm-$conversationId');
      _presence = channel;
      channel.onPresenceSync((_) {
        try {
          final state = channel.presenceState();
          var online = false;
          for (final item in state) {
            final presences = item.presences;
            for (final p in presences) {
              final payload = p.payload;
              final uid = (payload['user_id'] ?? '').toString();
              if (uid.isNotEmpty && uid == otherUserId) online = true;
            }
          }
          if (otherOnline != online) {
            otherOnline = online;
            if (!online) otherLastSeen = DateTime.now();
            _safeNotify();
          }
        } catch (e) {
          debugPrint('presence sync parse: $e');
        }
      });
      channel.subscribe((status, [error]) async {
        if (status == RealtimeSubscribeStatus.subscribed) {
          try {
            await channel.track({
              'user_id': _uid,
              'online_at': DateTime.now().toIso8601String(),
            });
          } catch (e) {
            debugPrint('presence track failed: $e');
          }
        }
      });
    } catch (e) {
      debugPrint('presence channel failed: $e');
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
    final pr = _presence;
    _presence = null;
    if (pr != null) {
      unawaited(Supabase.instance.client.removeChannel(pr));
    }
    super.dispose();
  }
}
