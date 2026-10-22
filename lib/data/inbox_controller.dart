##############################################################################

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

  SupabaseClient get _db => Supabase.instance.client;

  void start() {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    if (_uid == uid && _channel != null) return;
    stop();
    _uid = uid;
    unawaited(NotificationService.instance.init());
    refreshUnread();
    refreshMessageUnread();
    _channel = _db
        .channel('twice-inbox-$uid')
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

    // Fallback when the notification trigger is delayed for DMs.
    _msgChannel = _db
        .channel('twice-messages-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload) {
            final row = Map<String, dynamic>.from(payload.newRecord);
            final inOpenChat = activeConversationId != null &&
                (row['conversation_id'] ?? '').toString() ==
                    activeConversationId;
            if (!viewing && !inOpenChat) {
              refreshMessageUnread();
            }
            final sender = (row['sender_id'] ?? '').toString();
            if (!inOpenChat && sender.isNotEmpty && sender != uid) {
              // Only toast if we are not already in a focused viewing state
              // for messages; InboxController.viewing is Activity/Messages list.
              // Conversation page sets its own read state.
              unawaited(
                NotificationService.instance.presentFromRow({
                  'id': row['id'],
                  'type': 'message',
                  'actor_id': sender,
                  'body': (row['body'] ?? '').toString(),
                  'created_at': row['created_at'],
                  'conversation_id': row['conversation_id'],
                }),
              );
            }
          },
        )
        .subscribe();

    _poll = Timer.periodic(const Duration(seconds: 45), (_) {
      refreshUnread();
      refreshMessageUnread();
    });
  }

  void stop() {
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
        notifyListeners();
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
          .rpc(
            'twice_unread_conversation_count',
            params: {'p_user_id': uid},
          )
          .timeout(const Duration(seconds: 12));
      final count = (rows is int) ? rows : int.tryParse('$rows') ?? 0;
      if (count != messageUnread) {
        messageUnread = count;
        notifyListeners();
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
      // Mark related message notifications as read.
      try {
        await _db
            .from('notifications')
            .update({'is_read': true})
            .eq('recipient_id', uid)
            .eq('type', 'message')
            .eq('is_read', false);
      } catch (_) {}
      await refreshMessageUnread();
      await refreshUnread();
    } catch (e) {
      debugPrint('markConversationRead failed: $e');
    }
  }
}
