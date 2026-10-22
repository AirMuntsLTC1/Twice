import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_service.dart';

@pragma('vm:entry-point')
Future<void> twiceFirebaseBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
}

class PushNotificationService {
  PushNotificationService._();

  static final instance = PushNotificationService._();

  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  StreamSubscription<AuthState>? _authSubscription;
  bool _started = false;

  Future<void> init() async {
    if (_started || kIsWeb || !Platform.isAndroid) return;

    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();

      await NotificationService.instance.init();

      FirebaseMessaging.onBackgroundMessage(twiceFirebaseBackgroundHandler);

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();

      _messageSubscription = FirebaseMessaging.onMessage.listen((message) {
        unawaited(_presentMessage(message));
      });

      _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
        _openMessage,
      );

      _tokenSubscription = messaging.onTokenRefresh.listen((_) {
        unawaited(registerToken());
      });

      _authSubscription = Supabase.instance.client.auth.onAuthStateChange
          .listen((event) {
            if (event.session != null) {
              unawaited(registerToken());
            } else {
              unawaited(clearToken());
            }
          });

      _started = true;
      await registerToken();

      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _openMessage(initial);
        });
      }
    } catch (error) {
      debugPrint('Twice push setup failed: $error');
    }
  }

  TwiceNotificationEvent _eventFromMessage(RemoteMessage message) {
    final data = message.data;
    final notification = message.notification;

    String? value(String key) {
      final result = data[key]?.toString();
      return result == null || result.isEmpty ? null : result;
    }

    final type = value('type') ?? 'notification';

    return TwiceNotificationEvent(
      id:
          value('id') ??
          message.messageId ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      type: type,
      title:
          value('title') ??
          notification?.title ??
          TwiceNotificationEvent.friendlyTitle(type),
      body:
          value('body') ??
          notification?.body ??
          TwiceNotificationEvent.defaultBody(type, value('actorName') ?? ''),
      actorId: value('actorId'),
      actorName: value('actorName'),
      actorAvatar: value('actorAvatar'),
      postId: value('postId'),
      conversationId: value('conversationId'),
      storyId: value('storyId'),
      commentId: value('commentId'),
      createdAt: DateTime.tryParse(value('createdAt') ?? ''),
    );
  }

  Future<void> _presentMessage(RemoteMessage message) async {
    await NotificationService.instance.present(_eventFromMessage(message));
  }

  void _openMessage(RemoteMessage message) {
    NotificationService.instance.onTap?.call(_eventFromMessage(message));
  }

  Future<void> registerToken() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user == null) {
        debugPrint('TWICE_PUSH token registration skipped: no signed-in user');
        return;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) {
        debugPrint('TWICE_PUSH Firebase returned no FCM token');
        return;
      }

      await client.from('device_push_tokens').upsert({
        'user_id': user.id,
        'token': token,
        'platform': 'android',
        'device_label': 'Android',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'token');

      debugPrint('TWICE_PUSH token registered successfully');
    } catch (error) {
      debugPrint('TWICE_PUSH token registration failed: $error');
    }
  }

  /// Remove this device token (call on sign-out).
  Future<void> clearToken() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await Supabase.instance.client
          .from('device_push_tokens')
          .delete()
          .eq('token', token);
      await FirebaseMessaging.instance.deleteToken();
    } catch (error) {
      debugPrint('Twice push token clear failed: $error');
    }
  }

  Future<void> dispose() async {
    await _tokenSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _openedSubscription?.cancel();
    await _authSubscription?.cancel();
    _started = false;
  }
}
