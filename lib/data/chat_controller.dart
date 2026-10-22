import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_media.dart';
import 'chat_repository.dart';
import 'inbox_controller.dart';
import 'local_cache.dart';

enum ChatSendStatus { sending, sent, failed }

/// One photo/video inside a message. [mediaUrl] is the STORAGE PATH (stable),
/// never a signed URL.
class ChatAttachment {
  const ChatAttachment({
    required this.mediaUrl,
    this.mediaType = 'image',
    this.position = 0,
    this.localPath,
  });

  final String mediaUrl;
  final String mediaType;
  final int position;
  final String? localPath;

  ChatAttachment copyWith({String? localPath}) => ChatAttachment(
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        position: position,
        localPath: localPath ?? this.localPath,
      );

  Map<String, dynamic> toMap() => {
        'media_url': mediaUrl,
        'media_type': mediaType,
        'position': position,
        'local_path': localPath,
      };

  static ChatAttachment fromMap(Map<String, dynamic> m) => ChatAttachment(
        mediaUrl: (m['media_url'] ?? '').toString(),
        mediaType: (m['media_type'] ?? 'image').toString(),
        position: int.tryParse('${m['position'] ?? 0}') ?? 0,
        localPath: (m['local_path'] ?? m['local_file_path'])?.toString(),
      );
}

/// Chat row used by the UI. [clientId] never changes for a bubble (even when
/// the server id arrives), so Flutter keeps the same widget and nothing
/// flickers.
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
    this.attachments = const [],
    this.status = ChatSendStatus.sent,
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
  final List<ChatAttachment> attachments;
  final ChatSendStatus status;
  final String? localFilePath;

  bool get isMine {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    return uid != null && senderId == uid;
  }

  bool get isLocal => id.startsWith('local-');
  bool get isAlbum => attachments.length > 1;
  bool get hasMedia =>
      (mediaUrl ?? '').isNotEmpty ||
      (localFilePath ?? '').isNotEmpty ||
      attachments.isNotEmpty;

  ChatMessage copyWith({
    String? id,
    String? clientId,
    String? body,
    DateTime? createdAt,
    String? mediaUrl,
    String? mediaType,
    List<ChatAttachment>? attachments,
    ChatSendStatus? status,
    String? localFilePath,
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
      attachments: attachments ?? this.attachments,
      status: status ?? this.status,
      localFilePath: localFilePath ?? this.localFilePath,
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
        'attachments': attachments.map((a) => a.toMap()).toList(),
        'status': status.name,
        'local_file_path': localFilePath,
      };

  static ChatMessage fromRow(Map<String, dynamic> m) {
    final id = (m['id'] ?? '').toString();
    final atts = <ChatAttachment>[];
    final raw = m['attachments'];
    if (raw is List) {
      for (final a in raw) {
        if (a is Map) atts.add(ChatAttachment.fromMap(Map<String, dynamic>.from(a)));
      }
      atts.sort((a, b) => a.position.compareTo(b.position));
    }
    final media = (m['media_url'] ?? '').toString();
    return ChatMessage(
      id: id,
      clientId: id,
      conversationId: (m['conversation_id'] ?? '').toString(),
      senderId: (m['sender_id'] ?? '').toString(),
      body: (m['body'] ?? '').toString(),
      createdAt: DateTime.tryParse((m['created_at'] ?? '').toString()) ??
          DateTime.now().toUtc(),
      mediaUrl: media.isEmpty ? null : media,
      mediaType: (m['media_type'] ?? '').toString().isEmpty
          ? null
          : m['media_type'].toString(),
      attachments: atts,
    );
  }

  static ChatMessage? fromCacheMap(Map<String, dynamic> m) {
    final id = (m['id'] ?? '').toString();
    if (id.isEmpty) return null;
    var status = ChatSendStatus.sent;
    final s = (m['status'] ?? '').toString();
    // A bubble that was still "sending" when the app died is not delivered.
    if (s == 'sending' || s == 'failed') status = ChatSendStatus.failed;
    final atts = <ChatAttachment>[];
    final raw = m['attachments'] ?? m['resolved_attachments'];
    if (raw is List) {
      for (final a in raw) {
        if (a is Map) atts.add(ChatAttachment.fromMap(Map<String, dynamic>.from(a)));
      }
    }
    final media = (m['media_url'] ?? '').toString();
    // Old cache format stored signed URLs; never trust those.
    final looksSigned = media.startsWith('http');
    return ChatMessage(
      id: id,
      clientId: (m['client_id'] ?? id).toString(),
      conversationId: (m['conversation_id'] ?? '').toString(),
      senderId: (m['sender_id'] ?? '').toString(),
      body: (m['body'] ?? '').toString(),
      createdAt: DateTime.tryParse((m['created_at'] ?? '').toString()) ??
          DateTime.now().toUtc(),
      mediaUrl: media.isEmpty || looksSigned ? null : media,
      mediaType: (m['media_type'] ?? '').toString().isEmpty
          ? null
          : m['media_type'].toString(),
      attachments: atts.where((a) => !a.mediaUrl.startsWith('http')).toList(),
      status: status,
      localFilePath: m['local_file_path']?.toString(),
    );
  }
}

/// A long-lived "chat session" for one conversation (like Telegram).
///
///  * Opening a chat shows memory/disk messages INSTANTLY (no spinner).
///  * One-time silent delta sync fills only what is new.
///  * Realtime inserts are applied in place: no refetch, no list rebuild.
///  * Media is keyed by storage path, so thumbnails never go blank.
///  * Sends are optimistic and confirmed with the saved row (no guessing).
///  * Sessions outlive the page, so an upload keeps going if you leave.
class ChatController extends ChangeNotifier {
  ChatController._(this.conversationId, this._owner);

  static final Map<String, ChatController> _registry = {};

  /// Shared session for the current account + conversation.
  static ChatController obtain(String conversationId) {
    final uid = Supabase.instance.client.auth.currentUser?.id ?? '';
    final key = '$uid:$conversationId';
    var c = _registry[key];
    if (c == null) {
      c = ChatController._(conversationId, uid);
      _registry[key] = c;
      _evict();
    }
    c._lastUsed = DateTime.now();
    return c;
  }

  static void _evict() {
    if (_registry.length <= 10) return;
    final idle = _registry.entries
        .where((e) => e.value._attached == 0 && e.value._pendingSends == 0)
        .toList()
      ..sort((a, b) => a.value._lastUsed.compareTo(b.value._lastUsed));
    while (_registry.length > 10 && idle.isNotEmpty) {
      final e = idle.removeAt(0);
      _registry.remove(e.key);
      e.value.dispose();
    }
  }

  /// Call on logout so no chat state leaks to another account.
  static void resetAll() {
    final all = _registry.values.toList();
    _registry.clear();
    for (final c in all) {
      c.dispose();
    }
  }

  static const _pageSize = 40;

  final String conversationId;
  final String _owner;

  final List<ChatMessage> _messages = [];
  final Set<String> _fresh = {};
  bool loading = true;
  String? error;
  bool hasMore = true;
  bool loadingOlder = false;

  bool otherOnline = false;
  bool otherTyping = false;
  String? otherUserId;
  DateTime? otherLastSeen;
  DateTime? _peerReadUpTo;

  RealtimeChannel? _channel;
  RealtimeChannel? _presence;
  Timer? _ticker;
  Timer? _persistTimer;
  Timer? _readTimer;
  Timer? _typingTimer;

  int _attached = 0;
  int _pendingSends = 0;
  int _tick = 0;
  bool _disposed = false;
  bool _foreground = true;
  bool _live = false;
  bool _everLive = false;
  bool _syncing = false;
  bool _syncAgain = false;
  bool _typing = false;
  bool _presenceReady = false;
  bool _cacheLoaded = false;
  DateTime _lastUsed = DateTime.now();

  List<ChatMessage> get messages => _messages;
  bool get sending => _pendingSends > 0;

  /// True for bubbles that arrived live this session (used for the enter
  /// animation only; history never animates).
  bool isFresh(ChatMessage m) => _fresh.contains(m.clientId);

  String get _uid => Supabase.instance.client.auth.currentUser?.id ?? '';
  String get _cacheKey => 'chat_v2_$conversationId';
  ChatRepository get _repo => ChatRepository.instance;

  bool isRead(ChatMessage m) {
    final up = _peerReadUpTo;
    return m.senderId == _uid &&
        up != null &&
        m.status == ChatSendStatus.sent &&
        !up.isBefore(m.createdAt);
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> attach({String? peerUserId}) async {
    if (_disposed || _owner != _uid) return;
    _lastUsed = DateTime.now();
    if (peerUserId != null && peerUserId.isNotEmpty) otherUserId = peerUserId;
    _attached++;
    if (_messages.isEmpty && !_cacheLoaded) await _loadFromCache();
    if (_disposed) return;
    if (_attached == 1) {
      _foreground = true;
      _subscribe();
      unawaited(_trackPresence());
      _startTicker();
    }
    if (_messages.isNotEmpty && loading) {
      loading = false;
      _safeNotify();
    }
    unawaited(syncSilently(initial: _messages.isEmpty));
    _scheduleMarkRead();
    unawaited(_pollReceipts());
  }

  void detach() {
    _attached = _attached > 0 ? _attached - 1 : 0;
    if (_attached > 0) return;
    _ticker?.cancel();
    _ticker = null;
    _readTimer?.cancel();
    _typingTimer?.cancel();
    _typing = false;
    final ch = _channel;
    _channel = null;
    _live = false;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
    final pr = _presence;
    _presence = null;
    _presenceReady = false;
    otherOnline = false;
    otherTyping = false;
    if (pr != null) {
      unawaited(Supabase.instance.client.removeChannel(pr));
    }
    _persistNow();
  }

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value && _attached > 0) {
      unawaited(syncSilently());
      unawaited(_pollReceipts());
      _scheduleMarkRead();
      unawaited(_pushPresence());
    } else if (!value) {
      _typing = false;
      final pr = _presence;
      if (pr != null && _presenceReady) {
        unawaited(pr.untrack().then<void>((_) {}, onError: (Object _) {}));
      }
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _tick = 0;
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed || !_foreground || _attached == 0) return;
      _tick++;
      unawaited(_pollReceipts());
      // Realtime is the fast path; this is only a safety net for gaps.
      if (!_live || _tick % 9 == 0) unawaited(syncSilently());
    });
  }

  // ------------------------------------------------------------------- cache

  Future<void> _loadFromCache() async {
    _cacheLoaded = true;
    if (_uid.isEmpty) return;
    try {
      final raw = await LocalCache.instance.get(_uid, _cacheKey);
      if (raw is! List) return;
      final parsed = <ChatMessage>[];
      for (final item in raw) {
        if (item is Map) {
          final m = ChatMessage.fromCacheMap(Map<String, dynamic>.from(item));
          if (m != null && m.conversationId == conversationId) parsed.add(m);
        }
      }
      if (parsed.isEmpty || _messages.isNotEmpty) return;
      _messages.addAll(parsed);
      _sort();
      loading = false;
      _safeNotify();
    } catch (e) {
      debugPrint('Chat cache load failed: $e');
    }
  }

  void _persistSoon() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 700), _persistNow);
  }

  void _persistNow() {
    _persistTimer?.cancel();
    if (_owner.isEmpty) return;
    final slice = _messages.length > 120
        ? _messages.sublist(_messages.length - 120)
        : List<ChatMessage>.of(_messages);
    unawaited(
      LocalCache.instance
          .put(_owner, _cacheKey, slice.map((m) => m.toCacheMap()).toList())
          .catchError((Object e) => debugPrint('Chat cache write failed: $e')),
    );
  }

  // -------------------------------------------------------------------- sync

  ChatMessage? _lastServerMessage() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (!m.isLocal && m.status == ChatSendStatus.sent) return m;
    }
    return null;
  }

  /// Silent background sync: no spinner, no list reset. Only new/changed rows
  /// are merged in place.
  Future<void> syncSilently({bool initial = false}) async {
    if (_disposed || _owner != _uid) return;
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    try {
      var changed = false;
      final last = _lastServerMessage();
      if (last == null) {
        final rows = await _repo.latest(conversationId, limit: _pageSize);
        if (rows.length < _pageSize) hasMore = false;
        changed = _mergeRows(rows, fresh: false);
      } else {
        var since = last.createdAt.subtract(const Duration(seconds: 2));
        for (var page = 0; page < 5; page++) {
          final rows = await _repo.after(conversationId, since, limit: 100);
          if (_mergeRows(rows, fresh: true)) changed = true;
          if (rows.length < 100) break;
          final newest = DateTime.tryParse(
            (rows.last['created_at'] ?? '').toString(),
          );
          if (newest == null) break;
          since = newest;
        }
      }
      error = null;
      if (loading) {
        loading = false;
        changed = true;
      }
      if (changed) {
        _commit();
        _scheduleMarkRead();
      }
    } catch (e) {
      if (_messages.isEmpty) error = e.toString();
      if (loading) {
        loading = false;
        _safeNotify();
      }
    } finally {
      _syncing = false;
      if (_syncAgain && !_disposed) {
        _syncAgain = false;
        unawaited(syncSilently());
      }
    }
  }

  Future<void> loadOlder() async {
    if (loadingOlder || !hasMore || _disposed) return;
    ChatMessage? first;
    for (final m in _messages) {
      if (!m.isLocal && m.status == ChatSendStatus.sent) {
        first = m;
        break;
      }
    }
    if (first == null) return;
    loadingOlder = true;
    _safeNotify();
    try {
      final rows = await _repo.before(
        conversationId,
        first.createdAt,
        limit: _pageSize,
      );
      if (rows.length < _pageSize) hasMore = false;
      _mergeRows(rows, fresh: false);
      _commit();
    } catch (_) {
      // Keep hasMore so the user can scroll up to retry.
    } finally {
      loadingOlder = false;
      _safeNotify();
    }
  }

  Future<void> _pollReceipts() async {
    if (_disposed || !_foreground || _owner != _uid) return;
    try {
      _applyReadUpTo(await _repo.peerReadUpTo(conversationId));
    } catch (_) {}
  }

  void _applyReadUpTo(DateTime? d) {
    if (d == null) return;
    final cur = _peerReadUpTo;
    if (cur == null || d.isAfter(cur)) {
      _peerReadUpTo = d;
      _safeNotify();
    }
  }

  // ------------------------------------------------------------------- merge

  void _sort() {
    _messages.sort((a, b) {
      final c = a.createdAt.compareTo(b.createdAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  }

  bool _sameKind(ChatMessage local, ChatMessage server) {
    final lt = local.mediaType ?? '';
    final st = server.mediaType ?? '';
    if (lt == 'album') return st == 'image';
    return lt == st;
  }

  int _findPending(ChatMessage server, {required bool sendingOnly}) {
    if (server.senderId != _uid) return -1;
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m.status == ChatSendStatus.sent && !m.isLocal) continue;
      if (sendingOnly && m.status != ChatSendStatus.sending) continue;
      if (!sendingOnly && m.status == ChatSendStatus.sending) continue;
      if (m.senderId != server.senderId) continue;
      if (m.body != server.body || !_sameKind(m, server)) continue;
      if (m.createdAt.difference(server.createdAt).inMinutes.abs() > 5) continue;
      return i;
    }
    return -1;
  }

  List<ChatAttachment> _withLocalPaths(
    List<ChatAttachment> server,
    List<ChatAttachment> local,
  ) {
    if (server.isEmpty) return local;
    return [
      for (final s in server)
        s.copyWith(
          localPath: s.position < local.length ? local[s.position].localPath : null,
        ),
    ];
  }

  ChatMessage _adoptInto(ChatMessage local, ChatMessage server) {
    return server.copyWith(
      clientId: local.clientId,
      localFilePath: local.localFilePath,
      attachments: _withLocalPaths(server.attachments, local.attachments),
      status: ChatSendStatus.sent,
    );
  }

  /// Merges server rows into the list in place. Returns true if anything
  /// visible changed.
  bool _mergeRows(List<Map<String, dynamic>> rows, {required bool fresh}) {
    var changed = false;
    for (final row in rows) {
      final msg = ChatMessage.fromRow(row);
      if (msg.id.isEmpty || msg.conversationId != conversationId) continue;

      final existing = _messages.indexWhere((m) => m.id == msg.id);
      if (existing >= 0) {
        final old = _messages[existing];
        final attsChanged = msg.attachments.length > old.attachments.length;
        if (msg.body != old.body || attsChanged) {
          _messages[existing] = old.copyWith(
            body: msg.body,
            attachments: attsChanged
                ? _withLocalPaths(msg.attachments, old.attachments)
                : null,
          );
          changed = true;
        }
        continue;
      }

      // Our own message still being sent: the send call will adopt the row.
      if (_findPending(msg, sendingOnly: true) >= 0) continue;

      // A failed local bubble that the server actually has: adopt it.
      final failedIdx = _findPending(msg, sendingOnly: false);
      if (failedIdx >= 0) {
        _messages[failedIdx] = _adoptInto(_messages[failedIdx], msg);
        changed = true;
        continue;
      }

      _messages.add(msg);
      if (fresh &&
          DateTime.now().toUtc().difference(msg.createdAt.toUtc()).inSeconds.abs() <
              20) {
        _fresh.add(msg.clientId);
      }
      _warm(msg);
      changed = true;
    }
    if (changed) _sort();
    return changed;
  }

  void _warm(ChatMessage m) {
    if (m.isMine) return;
    if (m.attachments.isNotEmpty) {
      for (final a in m.attachments) {
        if (a.mediaType != 'video') ChatMediaStore.instance.prefetch(a.mediaUrl);
      }
    } else if ((m.mediaUrl ?? '').isNotEmpty && m.mediaType != 'video') {
      ChatMediaStore.instance.prefetch(m.mediaUrl!);
    }
  }

  void _commit() {
    _safeNotify();
    _persistSoon();
  }

  // ---------------------------------------------------------------- realtime

  void _subscribe() {
    final client = Supabase.instance.client;
    final old = _channel;
    _channel = null;
    if (old != null) unawaited(client.removeChannel(old));

    // Unique topic per attach so a quick leave/re-enter never collides with
    // the previous channel that is still closing.
    final topic = 'chat-$conversationId-${DateTime.now().microsecondsSinceEpoch}';
    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'conversation_id',
      value: conversationId,
    );
    _channel = client
        .channel(topic)
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: filter,
          callback: (payload) =>
              unawaited(_onInsert(Map<String, dynamic>.from(payload.newRecord))),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          filter: filter,
          callback: (payload) =>
              _onUpdate(Map<String, dynamic>.from(payload.newRecord)),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_attachments',
          filter: filter,
          callback: (payload) =>
              _onAttachment(Map<String, dynamic>.from(payload.newRecord)),
        )
        .subscribe((status, [error]) {
      if (_disposed) return;
      if (status == RealtimeSubscribeStatus.subscribed) {
        _live = true;
        // Re-connected: fill any gap silently.
        if (_everLive) unawaited(syncSilently());
        _everLive = true;
      } else if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut ||
          status == RealtimeSubscribeStatus.closed) {
        _live = false;
      }
    });
  }

  Future<void> _onInsert(Map<String, dynamic> row) async {
    final id = (row['id'] ?? '').toString();
    if (id.isEmpty || _messages.any((m) => m.id == id)) return;
    final mine = (row['sender_id'] ?? '').toString() == _uid;
    final media = (row['media_type'] ?? '').toString();

    // Photos from someone else may be an album whose attachment rows land a
    // moment after the parent. Wait briefly so it appears once, complete.
    if (!mine && media == 'image') {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (_disposed || _messages.any((m) => m.id == id)) return;
      try {
        row['attachments'] = await _repo.attachmentsFor(conversationId, [id]);
      } catch (_) {}
    }
    if (_mergeRows([row], fresh: true)) {
      _commit();
      if (!mine) _scheduleMarkRead();
    }
  }

  void _onUpdate(Map<String, dynamic> row) {
    final id = (row['id'] ?? '').toString();
    final idx = _messages.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    if (row['deleted_at'] != null) {
      _messages.removeAt(idx);
      _commit();
      return;
    }
    final body = (row['body'] ?? '').toString();
    if (body != _messages[idx].body) {
      _messages[idx] = _messages[idx].copyWith(body: body);
      _commit();
    }
  }

  void _onAttachment(Map<String, dynamic> row) {
    final id = (row['message_id'] ?? '').toString();
    final idx = _messages.indexWhere((m) => m.id == id);
    if (idx < 0) return; // parent not shown yet; it fetches its own set
    final att = ChatAttachment.fromMap(row);
    final cur = _messages[idx];
    if (cur.attachments.any((a) => a.position == att.position)) return;
    final next = [...cur.attachments, att]
      ..sort((a, b) => a.position.compareTo(b.position));
    _messages[idx] = cur.copyWith(attachments: next);
    if (!cur.isMine && att.mediaType != 'video') {
      ChatMediaStore.instance.prefetch(att.mediaUrl);
    }
    _commit();
  }

  // ---------------------------------------------------------------- presence

  Future<void> _trackPresence() async {
    final peer = otherUserId;
    if (peer == null || peer.isEmpty || _uid.isEmpty) return;
    try {
      final client = Supabase.instance.client;
      final old = _presence;
      _presence = null;
      _presenceReady = false;
      if (old != null) await client.removeChannel(old);
      if (_disposed || _attached == 0) return;

      // Both people must join the SAME topic to see each other.
      final channel = client.channel('presence-dm-$conversationId');
      _presence = channel;
      channel.onPresenceSync((_) {
        try {
          var online = false;
          var typing = false;
          for (final item in channel.presenceState()) {
            for (final p in item.presences) {
              final payload = p.payload;
              if ((payload['user_id'] ?? '').toString() != peer) continue;
              online = true;
              if (payload['typing'] == true) typing = true;
              final up = DateTime.tryParse('${payload['read_up_to'] ?? ''}');
              _applyReadUpTo(up);
            }
          }
          var changed = false;
          if (otherOnline != online) {
            otherOnline = online;
            if (!online) otherLastSeen = DateTime.now();
            changed = true;
          }
          if (otherTyping != typing) {
            otherTyping = typing;
            changed = true;
          }
          if (changed) _safeNotify();
        } catch (e) {
          debugPrint('presence sync parse: $e');
        }
      });
      channel.subscribe((status, [error]) async {
        if (status == RealtimeSubscribeStatus.subscribed) {
          _presenceReady = true;
          await _pushPresence();
        }
      });
    } catch (e) {
      debugPrint('presence channel failed: $e');
    }
  }

  Future<void> _pushPresence() async {
    final ch = _presence;
    if (ch == null || !_presenceReady || _uid.isEmpty || !_foreground) return;
    final last = _lastServerMessage();
    try {
      await ch.track({
        'user_id': _uid,
        'online_at': DateTime.now().toUtc().toIso8601String(),
        'typing': _typing,
        if (last != null) 'read_up_to': last.createdAt.toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('presence track failed: $e');
    }
  }

  /// Call from the composer; broadcasts "typing…" to the other person.
  void notifyTyping(bool typingNow) {
    _typingTimer?.cancel();
    if (typingNow) {
      _typingTimer = Timer(const Duration(seconds: 3), () => _setTyping(false));
      if (!_typing) _setTyping(true);
    } else if (_typing) {
      _setTyping(false);
    }
  }

  void _setTyping(bool v) {
    if (_typing == v) return;
    _typing = v;
    unawaited(_pushPresence());
  }

  void _scheduleMarkRead() {
    if (_disposed || !_foreground || _attached == 0) return;
    _readTimer?.cancel();
    _readTimer = Timer(const Duration(milliseconds: 600), () {
      if (_disposed || !_foreground || _attached == 0) return;
      unawaited(InboxController.instance.markConversationRead(conversationId));
      unawaited(_pushPresence());
    });
  }

  // ------------------------------------------------------------------- send

  ChatMessage _optimistic({
    required String clientId,
    String body = '',
    String? mediaType,
    String? localFilePath,
    List<ChatAttachment> attachments = const [],
  }) {
    return ChatMessage(
      id: clientId,
      clientId: clientId,
      conversationId: conversationId,
      senderId: _uid,
      body: body,
      createdAt: DateTime.now().toUtc(),
      mediaType: mediaType,
      localFilePath: localFilePath,
      attachments: attachments,
      status: ChatSendStatus.sending,
    );
  }

  void _addPending(ChatMessage m) {
    _messages.add(m);
    _fresh.add(m.clientId);
    _pendingSends++;
    _commit();
  }

  void _confirm(String clientId, Map<String, dynamic> row, {File? sentFile}) {
    final server = ChatMessage.fromRow(row);
    var idx = _messages.indexWhere((m) => m.clientId == clientId);
    final dup = _messages.indexWhere((m) => m.id == server.id);
    if (idx < 0) {
      if (dup < 0) _messages.add(server);
    } else {
      final local = _messages[idx];
      if (dup >= 0 && dup != idx) {
        _messages.removeAt(dup);
        idx = _messages.indexWhere((m) => m.clientId == clientId);
      }
      if (idx >= 0) _messages[idx] = _adoptInto(local, server);
    }
    if (sentFile != null && (server.mediaUrl ?? '').isNotEmpty) {
      ChatMediaStore.instance.registerSent(server.mediaUrl!, sentFile);
    }
    _sort();
    _commit();
    _persistNow();
  }

  void _fail(String clientId) {
    final idx = _messages.indexWhere((m) => m.clientId == clientId);
    if (idx >= 0) {
      _messages[idx] = _messages[idx].copyWith(status: ChatSendStatus.failed);
    }
    _commit();
    _persistNow();
    // The request may have reached the server even though the reply was
    // lost: a silent sync adopts it instead of leaving a duplicate.
    unawaited(syncSilently());
  }

  Future<void> sendText(String body) async {
    final text = body.trim();
    if (text.isEmpty || _uid.isEmpty) return;
    final clientId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    _addPending(_optimistic(clientId: clientId, body: text));
    notifyTyping(false);
    try {
      final row = await _repo.sendText(conversationId, text);
      _confirm(clientId, row);
    } catch (_) {
      _fail(clientId);
    } finally {
      _pendingSends--;
      _safeNotify();
    }
  }

  Future<void> sendMediaFile({
    required File file,
    required String mediaType,
  }) async {
    if (_uid.isEmpty) return;
    final clientId = 'local-media-${DateTime.now().microsecondsSinceEpoch}';
    _addPending(
      _optimistic(
        clientId: clientId,
        mediaType: mediaType,
        localFilePath: file.path,
      ),
    );
    try {
      final row = await _repo.sendMedia(
        conversationId: conversationId,
        file: file,
        mediaType: mediaType,
      );
      // Videos are large; only photos are copied into the local cache.
      _confirm(clientId, row, sentFile: mediaType == 'video' ? null : file);
    } catch (_) {
      _fail(clientId);
    } finally {
      _pendingSends--;
      _safeNotify();
    }
  }

  Future<void> sendMediaAlbum(List<File> files) async {
    if (files.isEmpty || _uid.isEmpty) return;
    final clientId = 'local-album-${DateTime.now().microsecondsSinceEpoch}';
    _addPending(
      _optimistic(
        clientId: clientId,
        mediaType: 'album',
        attachments: [
          for (var i = 0; i < files.length; i++)
            ChatAttachment(
              mediaUrl: '',
              position: i,
              localPath: files[i].path,
            ),
        ],
      ),
    );
    try {
      final row = await _repo.sendAlbum(
        conversationId: conversationId,
        files: files,
      );
      _confirm(clientId, row);
      final atts = (row['attachments'] as List?) ?? const [];
      for (var i = 0; i < atts.length && i < files.length; i++) {
        final path = ((atts[i] as Map)['media_url'] ?? '').toString();
        if (path.isNotEmpty) ChatMediaStore.instance.registerSent(path, files[i]);
      }
    } catch (_) {
      _fail(clientId);
    } finally {
      _pendingSends--;
      _safeNotify();
    }
  }

  Future<void> retry(ChatMessage failed) async {
    if (failed.status != ChatSendStatus.failed) return;
    _messages.removeWhere((m) => m.clientId == failed.clientId);
    _commit();
    if (failed.attachments.length > 1) {
      final files = <File>[
        for (final a in failed.attachments)
          if ((a.localPath ?? '').isNotEmpty && File(a.localPath!).existsSync())
            File(a.localPath!),
      ];
      if (files.isNotEmpty) await sendMediaAlbum(files);
    } else if ((failed.mediaType == 'image' || failed.mediaType == 'video') &&
        (failed.localFilePath ?? '').isNotEmpty &&
        File(failed.localFilePath!).existsSync()) {
      await sendMediaFile(
        file: File(failed.localFilePath!),
        mediaType: failed.mediaType!,
      );
    } else if (failed.body.trim().isNotEmpty) {
      await sendText(failed.body);
    }
  }

  /// Removes a failed bubble the user does not want to resend.
  void discard(ChatMessage failed) {
    _messages.removeWhere((m) => m.clientId == failed.clientId);
    _commit();
  }

  // ------------------------------------------------------------------ misc

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _persistTimer?.cancel();
    _readTimer?.cancel();
    _typingTimer?.cancel();
    final ch = _channel;
    _channel = null;
    if (ch != null) unawaited(Supabase.instance.client.removeChannel(ch));
    final pr = _presence;
    _presence = null;
    if (pr != null) unawaited(Supabase.instance.client.removeChannel(pr));
    super.dispose();
  }
}
