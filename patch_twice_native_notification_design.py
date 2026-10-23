from pathlib import Path
from datetime import datetime
import re
import shutil

root = Path.cwd()
target = root / "lib/data/notification_service.dart"
source = target.read_text()

if "twice_messages_v2" in source or "twice_social_v2" in source:
    print("STOP: notification design patch appears to be applied already.")
    print("No files changed.")
    raise SystemExit(0)

if source.count("Future<void> _showSystem(") != 1:
    raise SystemExit("STOP: expected exactly one _showSystem method.")

if "AndroidNotificationDetails(" not in source:
    raise SystemExit("STOP: Android notification configuration not found.")

if "onDidReceiveNotificationResponse:" not in source:
    raise SystemExit("STOP: notification tap routing callback not found.")

channel_pattern = re.compile(
    r"      if \(Platform\.isAndroid\) \{.*?\n      \}\n      _ready = true;",
    re.DOTALL,
)

channel_replacement = """      if (Platform.isAndroid) {
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
      _ready = true;"""

updated, channel_count = channel_pattern.subn(
    channel_replacement, source, count=1
)

if channel_count != 1:
    raise SystemExit(
        "STOP: couldn't safely locate the Android channel setup. "
        "No files changed."
    )

method_start = updated.find("  Future<void> _showSystem(")
class_end = updated.rfind("\n}")
if method_start < 0 or class_end < method_start:
    raise SystemExit("STOP: couldn't safely locate the system display method.")

new_method = r'''  Future<File?> _downloadNotificationAvatar(String? url) async {
    if (url == null || url.isEmpty) return null;

    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      return null;
    }

    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4);

      final request = await client.getUrl(uri).timeout(
        const Duration(seconds: 5),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );

      if (response.statusCode != HttpStatus.ok) return null;

      final declaredLength = response.contentLength;
      if (declaredLength > 2 * 1024 * 1024) return null;

      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) {
          if (buffer.length + chunk.length > 2 * 1024 * 1024) {
            throw const FormatException('Notification avatar is too large');
          }
          buffer.addAll(chunk);
          return buffer;
        },
      ).timeout(const Duration(seconds: 5));

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
      final channel = isMessage
          ? 'twice_messages_v2'
          : 'twice_social_v2';
      final channelName = isMessage ? 'Twice messages' : 'Twice activity';
      final groupKey = isMessage ? 'twice_messages_group' : 'twice_social_group';
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
  }'''

updated = updated[:method_start] + new_method + updated[class_end:]

stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
backup = root / "backups" / f"before-native-notification-design-{stamp}"
backup.mkdir(parents=True, exist_ok=False)
shutil.copy2(target, backup / target.name)

target.write_text(updated)
print("PATCH APPLIED")
print("Changed:", target.relative_to(root))
print("Backup:", backup.relative_to(root))
print("Design: versioned Android channels, separate groups, expanded text, optional sender avatar.")
print("No Firebase, Supabase, in-app banner, Activity screen, or tap callback code was intentionally changed.")
