import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    refreshUnread();
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
            final type = (payload.newRecord['type'] ?? '').toString();
            if (viewing) {
              markAllRead();
            } else {
              unread++;
              if (type == 'message') messageUnread++;
            }
            notifyListeners();
          },
        )
        .subscribe();

    // Also listen to new messages where the current user is a member.
    // (Fallback when the notification trigger is delayed.)
    _msgChannel = _db
        .channel('twice-messages-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (_) {
            if (!viewing) {
              refreshMessageUnread();
            }
          },
        )
        .subscribe();

    _poll = Timer.periodic(const Duration(seconds: 45), (_) {
      refreshUnread();
      refreshMessageUnread();
    });
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
      final rows = await _db.rpc(
        'twice_unread_conversation_count',
        params: {'p_user_id': uid},
      ).timeout(const Duration(seconds: 12));
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
    if (unread != 0 || messageUnread != 0) {
      unread = 0;
      messageUnread = 0;
      notifyListeners();
    }
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
    if (uid == null) return;
    try {
      await _db
          .from('conversation_members')
          .update({'last_read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('conversation_id', conversationId)
          .eq('user_id', uid);
      await refreshMessageUnread();
    } catch (_) {}
  }

  void stop() {
    _poll?.cancel();
    _poll = null;
    for (final ch in [_channel, _msgChannel]) {
      if (ch != null) {
        try {
          unawaited(_db.removeChannel(ch));
        } catch (_) {}
      }
    }
    _channel = null;
    _msgChannel = null;
    _uid = null;
    unread = 0;
    messageUnread = 0;
    viewing = false;
  }
}
