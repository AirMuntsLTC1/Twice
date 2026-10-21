import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Keeps the unread inbox count live (Supabase realtime + a 60s safety poll).
class InboxController extends ChangeNotifier {
  InboxController._();
  static final InboxController instance = InboxController._();

  int unread = 0;
  int version = 0; // bumps whenever the list should reload
  bool viewing = false; // true while the Inbox tab is open
  RealtimeChannel? _channel;
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
            if (viewing) {
              markAllRead();
            } else {
              unread++;
            }
            notifyListeners();
          },
        )
        .subscribe();
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => refreshUnread());
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
          .limit(100)
          .timeout(const Duration(seconds: 15));
      final count = (rows as List).length;
      if (count != unread) {
        unread = count;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> markAllRead() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    if (unread != 0) {
      unread = 0;
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

  /// Silent reset (called while the shell is being disposed).
  void stop() {
    _poll?.cancel();
    _poll = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        unawaited(_db.removeChannel(channel));
      } catch (_) {}
    }
    _uid = null;
    unread = 0;
    viewing = false;
  }
}
