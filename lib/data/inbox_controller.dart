import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_service.dart';

/// Live unread badge for the shell (home tab + Messages entry).
/// Matches Instagram: badge updates instantly when a new message/notification
/// arrives, clears when the user opens the inbox.
class InboxController extends ChangeNotifier {
  InboxController._();
  static final InboxController instance = InboxController._();

  int unread = 0;
  int messageUnread = 0;
  bool viewing = false;
  int version = 0;

  /// Conversation currently open on screen. Incoming messages for it must not
  /// pop a banner or bump the unread badge (the chat shows them live).
  String? activeConversationId;

  RealtimeChannel? _channel;
  RealtimeChannel? _msgChannel;
  Timer? _poll;
  String? _uid;
  StreamSubscription<AuthState>? _authSub;
  bool _foreground = true;
  Timer? _notifyDebounce;

  /// Coalesces bursts of unread changes into one rebuild (stops the badge
  /// from flickering when several realtime events + polls land together).
  void _notifySoon() {
    if (_notifyDebounce?.isActive ?? false) return;
    _notifyDebounce = Timer(const Duration(milliseconds: 60), notifyListeners);
  }

  /// Called by the shell on every lifecycle change. Polling and live channels
  /// are paused while the app is in the background (push covers that case)
  /// and everything is refreshed once when the app comes back.
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      if (_uid != null) {
        refreshUnread();
        refreshMessageUnread();
      }
      _startPolling();
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _startPolling() {
    _poll?.cancel();
    if (_uid == null || !_foreground) return;
    _poll = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!_foreground) return;
      refreshUnread();
      refreshMessageUnread();
    });
  }

  SupabaseClient get _db => Supabase.instance.client;

  void start() {
    _authSub ??= _db.auth.onAuthStateChange.listen((event) {
      final id = event.session?.user.id;
      if (id == null) {
        _teardown();
        unread = 0;
        messageUnread = 0;
        notifyListeners();
      } else if (id != _uid) {
        _connect();
      }
    });
    _connect();
  }

  bool _connecting = false;

  void _connect() {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    if (_uid == uid && _channel != null) return;
    if (_connecting) return;
    _connecting = true;
    _teardown();
    _uid = uid;
    unawaited(NotificationService.instance.init());
    refreshUnread();
    refreshMessageUnread();
    _channel = _db
        .channel('twice-inbox-v2-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'recipient_id',
            value: uid,
          ),
          callback: (payload) {
            version++;
            final row = Map<String, dynamic>.from(payload.newRecord);
            final type = (row['type'] ?? '').toString();
            if (type == 'message' && activeConversationId != null) {
              final convo = (row['conversation_id'] ?? '').toString();
              if (convo.isEmpty || convo == activeConversationId) {
                // Already looking at this chat; it is marked read there.
                return;
              }
            }
            if (viewing) {
              markAllRead();
            } else {
              unread++;
              if (type == 'message') messageUnread++;
            }
            notifyListeners();
            // Top slide banner + system notification
            unawaited(NotificationService.instance.presentFromRow(row));
          },
        )
        .subscribe();

    // Notification presentation for DMs is handled once by the
    // notifications channel above (trigger twice_message_notify creates a row
    // for every message). Subscribing to messages here previously caused a
    // second banner/system notification for the same DM. This channel only
    // refreshes the unread count.
    _msgChannel = _db
        .channel('twice-messages-count-v2-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload) {
            final row = Map<String, dynamic>.from(payload.newRecord);
            final inOpenChat =
                activeConversationId != null &&
                (row['conversation_id'] ?? '').toString() ==
                    activeConversationId;
            if (!viewing && !inOpenChat) {
              refreshMessageUnread();
            }
          },
        )
        .subscribe();

    _startPolling();
  }

  void stop() {
    _authSub?.cancel();
    _authSub = null;
    _notifyDebounce?.cancel();
    _teardown();
  }

  void _teardown() {
    _connecting = false;
    _poll?.cancel();
    _poll = null;
    final ch = _channel;
    final msg = _msgChannel;
    _channel = null;
    _msgChannel = null;
    if (ch != null) {
      unawaited(_db.removeChannel(ch));
    }
    if (msg != null) {
      unawaited(_db.removeChannel(msg));
    }
    _uid = null;
  }

  Future<void> refreshUnread() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final rows = await _db
          .from('notifications')
          .select('id')
          .eq('recipient_id', uid)
          .eq('is_read', false)
          .limit(200)
          .timeout(const Duration(seconds: 12));
      final count = (rows as List).length;
      if (count != unread) {
        unread = count;
        _notifySoon();
      }
    } catch (_) {}
  }

  /// Unread conversations = member rows where last_read_at is null or
  /// older than the latest message in that conversation.
  Future<void> refreshMessageUnread() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final rows = await _db
          .rpc('twice_unread_conversation_count', params: {'p_user_id': uid})
          .timeout(const Duration(seconds: 12));
      final count = (rows is int) ? rows : int.tryParse('$rows') ?? 0;
      if (count != messageUnread) {
        messageUnread = count;
        _notifySoon();
      }
    } catch (_) {
      // RPC may not exist yet — fall back to notification type=message count.
      try {
        final rows = await _db
            .from('notifications')
            .select('id')
            .eq('recipient_id', uid)
            .eq('type', 'message')
            .eq('is_read', false)
            .limit(100);
        final count = (rows as List).length;
        if (count != messageUnread) {
          messageUnread = count;
          notifyListeners();
        }
      } catch (_) {}
    }
  }

  Future<void> markAllRead() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    unread = 0;
    messageUnread = 0;
    notifyListeners();
    try {
      await _db
          .from('notifications')
          .update({'is_read': true})
          .eq('recipient_id', uid)
          .eq('is_read', false);
    } catch (_) {}
  }

  Future<void> markConversationRead(String conversationId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null || conversationId.isEmpty) return;
    try {
      await _db
          .from('conversation_members')
          .update({'last_read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('conversation_id', conversationId)
          .eq('user_id', uid);
      // Mark only THIS chat's message notifications as read. The
      // notifications table has no conversation_id column, so match on the
      // other members of the conversation (previously every chat's
      // notifications were cleared whenever any single chat was opened).
      try {
        final members = await _db
            .from('conversation_members')
            .select('user_id')
            .eq('conversation_id', conversationId)
            .neq('user_id', uid);
        final others = (members as List)
            .map((row) => (row as Map)['user_id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toList();
        if (others.isNotEmpty) {
          await _db
              .from('notifications')
              .update({'is_read': true})
              .eq('recipient_id', uid)
              .eq('type', 'message')
              .eq('is_read', false)
              .inFilter('actor_id', others);
        }
      } catch (_) {}
      await refreshMessageUnread();
      await refreshUnread();
    } catch (e) {
      debugPrint('markConversationRead failed: $e');
    }
  }
}
