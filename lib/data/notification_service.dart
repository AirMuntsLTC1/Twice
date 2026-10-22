import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'twice_native_notifications.dart';

/// One in-app / system notification event.
class TwiceNotificationEvent {
  TwiceNotificationEvent({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.actorId,
    this.actorName,
    this.actorAvatar,
    this.postId,
    this.conversationId,
    this.storyId,
    this.commentId,
    this.createdAt,
  });

  final String id;
  final String type;
  final String title;
  final String body;
  final String? actorId;
  final String? actorName;
  final String? actorAvatar;
  final String? postId;
  final String? conversationId;
  final String? storyId;
  final String? commentId;
  final DateTime? createdAt;

  static String friendlyTitle(String type) {
    switch (type) {
      case 'message':
        return 'New message';
      case 'like':
        return 'New like';
      case 'comment':
        return 'New comment';
      case 'reply':
        return 'New reply';
      case 'follow':
        return 'New follower';
      case 'follow_request':
        return 'Follow request';
      case 'follow_accept':
        return 'Follow accepted';
      case 'save':
        return 'Post saved';
      case 'story_reaction':
        return 'Story reaction';
      case 'story_reply':
        return 'Story reply';
      default:
        return 'Notification';
    }
  }

  static String defaultBody(String type, String actor) {
    final who = actor.isEmpty ? 'Someone' : actor;
    switch (type) {
      case 'message':
        return '$who sent you a message';
      case 'like':
        return '$who liked your post';
      case 'comment':
        return '$who commented on your post';
      case 'reply':
        return '$who replied to your comment';
      case 'follow':
        return '$who started following you';
      case 'follow_request':
        return '$who requested to follow you';
      case 'follow_accept':
        return '$who accepted your follow request';
      case 'save':
        return '$who saved your post';
      case 'story_reaction':
        return '$who reacted to your story';
      case 'story_reply':
        return '$who replied to your story';
      default:
        return 'You have a new notification';
    }
  }
}

/// Global notification coordinator:
/// - in-app top slide banners (queue)
/// - Android/iOS local system notifications
/// Does not replace FCM push; works while the app process is alive and
/// can show system tray notifications on Android/iOS.
class NotificationService extends ChangeNotifier {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  final List<TwiceNotificationEvent> _queue = [];
  final Map<String, DateTime> _recentEvents = {};
  static const Duration _dedupeWindow = Duration(seconds: 5);
  TwiceNotificationEvent? current;
  bool _ready = false;
  bool _presenting = false;
  Timer? _autoHide;
  AppLifecycleState lifecycle = AppLifecycleState.resumed;

  /// Optional navigation hooks set by the shell.
  void Function(TwiceNotificationEvent event)? onTap;

  Future<void> init() async {
    if (_ready) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
        onDidReceiveNotificationResponse: (response) {
          final raw = response.payload;
          if (raw == null || raw.isEmpty) return;
          try {
            final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
            final event = TwiceNotificationEvent(
              id: (data['id'] ?? '').toString(),
              type: (data['type'] ?? '').toString(),
              title: (data['title'] ?? 'Notification').toString(),
              body: (data['body'] ?? '').toString(),
              actorId: data['actorId']?.toString(),
              actorName: data['actorName']?.toString(),
              actorAvatar: data['actorAvatar']?.toString(),
              postId: data['postId']?.toString(),
              conversationId: data['conversationId']?.toString(),
              storyId: data['storyId']?.toString(),
              commentId: data['commentId']?.toString(),
              createdAt: DateTime.tryParse(
                (data['createdAt'] ?? '').toString(),
              ),
            );
            onTap?.call(event);
          } catch (e) {
            debugPrint('Invalid notification payload: $e');
          }
        },
      );

      if (Platform.isAndroid) {
        final androidPlugin = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();

        await androidPlugin?.requestNotificationsPermission();

        // Versioned IDs apply the new importance settings without trying
        // to overwrite channel settings already saved by Android.
        await androidPlugin?.createNotificationChannel(
          const AndroidNotificationChannel(
            'twice_social_v2',
            'Twice activity',
            description: 'Likes, comments, follows and story activity',
            importance: Importance.low,
          ),
        );

        await androidPlugin?.createNotificationChannel(
          const AndroidNotificationChannel(
            'twice_messages_v2',
            'Twice messages',
            description: 'Direct messages',
            importance: Importance.high,
          ),
        );
      }
      _ready = true;
    } catch (e) {
      debugPrint('NotificationService init failed: $e');
      _ready = false;
    }
  }

  void setLifecycle(AppLifecycleState state) {
    lifecycle = state;
  }

  /// Display a system notification from an FCM background isolate.
  /// Does not enqueue an in-app banner or trigger foreground haptics.
  Future<void> presentBackground(TwiceNotificationEvent event) async {
    if (!_ready) await init();
    if (!_ready) return;
    await _showSystem(event);
  }

  /// Enqueue a notification for in-app banner + optional system tray.
  Future<void> present(TwiceNotificationEvent event) async {
    final now = DateTime.now();
    _recentEvents.removeWhere(
      (_, time) => now.difference(time) > _dedupeWindow,
    );
    final semanticKey = event.type == 'message'
        ? 'message|${event.actorId ?? ''}|${event.conversationId ?? ''}|${(event.createdAt?.toUtc().millisecondsSinceEpoch ?? 0) ~/ 1000}'
        : '${event.type}|${event.actorId ?? ''}|${event.postId ?? ''}|${event.storyId ?? ''}|${event.commentId ?? ''}|${event.body}';
    final previous = _recentEvents[semanticKey];
    if (previous != null && now.difference(previous) <= _dedupeWindow) return;
    _recentEvents[semanticKey] = now;
    _queue.add(event);
    final foreground = lifecycle == AppLifecycleState.resumed;
    int ageSeconds(TwiceNotificationEvent item) {
      final createdAt = item.createdAt;
      if (createdAt == null) return 0;
      return now.difference(createdAt).inSeconds.clamp(0, 2147483647).toInt();
    }

    _queue.sort((a, b) {
      final aPriority = TwiceNativeNotifications.instance.priorityFor(
        a.type,
        foreground,
        ageSeconds(a),
      );
      final bPriority = TwiceNativeNotifications.instance.priorityFor(
        b.type,
        foreground,
        ageSeconds(b),
      );
      return bPriority.compareTo(aPriority);
    });
    unawaited(_drain());
    // System notification when app is not actively focused.
    if (lifecycle != AppLifecycleState.resumed) {
      unawaited(_showSystem(event));
    } else {
      // Still show a subtle system notification on Android for parity
      // (user asked for phone notifications). Keep it light in foreground.
      unawaited(_showSystem(event, silent: true));
    }
  }

  Future<void> presentFromRow(Map<String, dynamic> row) async {
    final type = (row['type'] ?? '').toString();
    final id = (row['id'] ?? DateTime.now().microsecondsSinceEpoch.toString())
        .toString();
    String actorName = '';
    String? actorAvatar;
    final actorId = row['actor_id']?.toString();

    // Prefer embedded profile; otherwise resolve quickly.
    final embedded = row['profiles'] ?? row['actor_profile'];
    if (embedded is Map) {
      actorName = (embedded['display_name'] ?? embedded['username'] ?? '')
          .toString();
      actorAvatar = embedded['avatar_url']?.toString();
    } else if (actorId != null && actorId.isNotEmpty) {
      try {
        final p = await Supabase.instance.client
            .from('profiles')
            .select('username,display_name,avatar_url')
            .eq('id', actorId)
            .maybeSingle()
            .timeout(const Duration(seconds: 4));
        if (p != null) {
          final map = Map<String, dynamic>.from(p as Map);
          actorName = (map['display_name'] ?? map['username'] ?? '').toString();
          actorAvatar = map['avatar_url']?.toString();
        }
      } catch (_) {}
    }

    final bodyText = (row['body'] ?? '').toString().trim();
    final body = bodyText.isNotEmpty
        ? (actorName.isEmpty ? bodyText : '$actorName: $bodyText')
        : TwiceNotificationEvent.defaultBody(type, actorName);

    await present(
      TwiceNotificationEvent(
        id: id,
        type: type,
        title: TwiceNotificationEvent.friendlyTitle(type),
        body: body,
        actorId: actorId,
        actorName: actorName.isEmpty ? null : actorName,
        actorAvatar: actorAvatar,
        postId: row['post_id']?.toString(),
        conversationId: row['conversation_id']?.toString(),
        storyId: row['story_id']?.toString(),
        commentId: row['comment_id']?.toString(),
        createdAt: DateTime.tryParse((row['created_at'] ?? '').toString()),
      ),
    );
  }

  Future<void> _drain() async {
    if (_presenting) return;
    if (_queue.isEmpty) return;
    _presenting = true;
    current = _queue.removeAt(0);
    notifyListeners();
    unawaited(HapticFeedback.lightImpact());
    _autoHide?.cancel();
    _autoHide = Timer(const Duration(milliseconds: 3400), () {
      dismissCurrent();
    });
  }

  void dismissCurrent() {
    _autoHide?.cancel();
    current = null;
    notifyListeners();
    _presenting = false;
    // Next in queue
    if (_queue.isNotEmpty) {
      Future<void>.delayed(const Duration(milliseconds: 220), _drain);
    }
  }

  void handleTap() {
    final event = current;
    dismissCurrent();
    if (event != null) onTap?.call(event);
  }

  Future<File?> _downloadNotificationAvatar(String? url) async {
    if (url == null || url.isEmpty) return null;

    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      return null;
    }

    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 4);

      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );

      if (response.statusCode != HttpStatus.ok) return null;

      final declaredLength = response.contentLength;
      if (declaredLength > 2 * 1024 * 1024) return null;

      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) {
            if (buffer.length + chunk.length > 2 * 1024 * 1024) {
              throw const FormatException('Notification avatar is too large');
            }
            buffer.addAll(chunk);
            return buffer;
          })
          .timeout(const Duration(seconds: 5));

      if (bytes.isEmpty) return null;

      final directory = Directory.systemTemp;
      final file = File(
        '${directory.path}/twice_notification_avatar_${uri.toString().hashCode.abs()}.img',
      );

      await file.writeAsBytes(bytes, flush: false);
      return file;
    } catch (error) {
      debugPrint('Twice notification avatar unavailable: $error');
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> _showSystem(
    TwiceNotificationEvent event, {
    bool silent = false,
  }) async {
    if (!_ready) await init();
    if (!_ready) return;

    try {
      final isMessage = event.type == 'message';
      final channel = isMessage ? 'twice_messages_v2' : 'twice_social_v2';
      final channelName = isMessage ? 'Twice messages' : 'Twice activity';
      final groupKey = isMessage
          ? 'twice_messages_group'
          : 'twice_social_group';
      final summaryId = isMessage ? 0x545701 : 0x545702;

      final avatarFile = await _downloadNotificationAvatar(event.actorAvatar);
      final avatar = avatarFile == null
          ? null
          : FilePathAndroidBitmap(avatarFile.path);

      final android = AndroidNotificationDetails(
        channel,
        channelName,
        channelDescription: isMessage
            ? 'Direct messages'
            : 'Likes, comments, follows and story activity',
        importance: isMessage ? Importance.high : Importance.low,
        priority: isMessage ? Priority.high : Priority.low,
        playSound: !silent && isMessage,
        enableVibration: !silent && isMessage,
        onlyAlertOnce: true,
        icon: '@mipmap/ic_launcher',
        groupKey: groupKey,
        largeIcon: avatar,
        styleInformation: BigTextStyleInformation(
          event.body,
          contentTitle: event.title,
          summaryText: 'Twice',
        ),
      );

      final payload = jsonEncode({
        'id': event.id,
        'type': event.type,
        'title': event.title,
        'body': event.body,
        'actorId': event.actorId,
        'actorName': event.actorName,
        'actorAvatar': event.actorAvatar,
        'postId': event.postId,
        'conversationId': event.conversationId,
        'storyId': event.storyId,
        'commentId': event.commentId,
        'createdAt': event.createdAt?.toIso8601String(),
      });

      // Individual notifications remain independently tappable.
      await _plugin.show(
        event.id.hashCode & 0x7fffffff,
        event.title,
        event.body,
        NotificationDetails(
          android: android,
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: payload,
      );

      // Maintain one quiet Android group summary for messages and one for
      // social activity. Keep the same event payload for existing routing.
      final summaryAndroid = AndroidNotificationDetails(
        channel,
        channelName,
        channelDescription: isMessage
            ? 'Direct messages'
            : 'Likes, comments, follows and story activity',
        importance: isMessage ? Importance.high : Importance.low,
        priority: Priority.low,
        playSound: false,
        enableVibration: false,
        onlyAlertOnce: true,
        icon: '@mipmap/ic_launcher',
        groupKey: groupKey,
        setAsGroupSummary: true,
        styleInformation: BigTextStyleInformation(
          isMessage ? 'New messages' : 'New social activity',
          contentTitle: 'Twice',
        ),
      );

      await _plugin.show(
        summaryId,
        'Twice',
        isMessage ? 'New messages' : 'New social activity',
        NotificationDetails(android: summaryAndroid),
        payload: payload,
      );
    } catch (error) {
      debugPrint('system notification failed: $error');
    }
  }
}
