from pathlib import Path
from datetime import datetime
import shutil
import sys

push = Path("lib/data/push_notification_service.dart")
edge = Path("supabase/functions/twice-send-push/index.ts")

if not push.is_file() or not edge.is_file():
    sys.exit("FAIL: expected source file is missing.")

p = push.read_text()
e = edge.read_text()

old_handler = """@pragma('vm:entry-point')
Future<void> twiceFirebaseBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
}"""

new_handler = """@pragma('vm:entry-point')
Future<void> twiceFirebaseBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }

    // Data-only pushes need explicit local display in the background.
    await NotificationService.instance.init();
    NotificationService.instance.setLifecycle(AppLifecycleState.paused);

    final data = message.data;
    String? value(String key) {
      final result = data[key]?.toString();
      return result == null || result.isEmpty ? null : result;
    }

    final type = value('type') ?? 'notification';
    final event = TwiceNotificationEvent(
      id: value('id') ??
          message.messageId ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      type: type,
      title: value('title') ??
          TwiceNotificationEvent.friendlyTitle(type),
      body: value('body') ??
          TwiceNotificationEvent.defaultBody(
            type,
            value('actorName') ?? '',
          ),
      actorId: value('actorId'),
      actorName: value('actorName'),
      actorAvatar: value('actorAvatar'),
      postId: value('postId'),
      conversationId: value('conversationId'),
      storyId: value('storyId'),
      commentId: value('commentId'),
      createdAt: DateTime.tryParse(value('createdAt') ?? ''),
    );

    await NotificationService.instance.present(event);
  } catch (error, stack) {
    debugPrint('Twice background notification failed: $error');
    debugPrintStack(stackTrace: stack);
  }
}"""

old_fcm = """              notification: { title: text.title, body: text.body },
              data,
              android: {
                priority: "HIGH",
                notification: {
                  channel_id: type === "message" ? "twice_messages" : "twice_social",
                },
              },"""

new_fcm = """              // Data-only: Android must not auto-render a generic
              // notification; the app's local notification service handles it.
              data,
              android: {
                priority: "HIGH",
              },"""

if p.count(old_handler) != 1:
    sys.exit("FAIL: background handler did not match exactly once; no files changed.")
if e.count(old_fcm) != 1:
    sys.exit("FAIL: FCM payload block did not match exactly once; no files changed.")

stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
backups = [
    (push, Path(str(push) + f".backup-data-push-{stamp}")),
    (edge, Path(str(edge) + f".backup-data-push-{stamp}")),
]

for source, backup in backups:
    shutil.copy2(source, backup)

try:
    push.write_text(p.replace(old_handler, new_handler, 1))
    edge.write_text(e.replace(old_fcm, new_fcm, 1))
except Exception:
    for source, backup in backups:
        shutil.copy2(backup, source)
    sys.exit("FAIL: write failed; source files restored from backups.")

print("SUCCESS: background handler and FCM payload updated.")
for _, backup in backups:
    print(f"Backup: {backup}")
