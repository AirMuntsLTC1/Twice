# Twice Notification Fix Bundle

This is an overlay for the Twice Flutter project. It is based on the source archive available when this bundle was prepared.

## What this patch changes

- Keeps the global in-app banner queue and its top slide-in / swipe-up dismissal.
- Preserves actor profile/avatar data and contextual IDs in notification payloads.
- Routes taps on local system notifications through `NotificationService.onTap` instead of logging the payload only.
- Adds short-window duplicate suppression so a message received from both the `notifications` and `messages` Realtime subscriptions is less likely to appear twice.
- Adds a secure, user-scoped Supabase table for device push tokens as the backend foundation for remote push.
- Does not change Gradle, AGP, Kotlin, NDK, Flutter, or Android SDK versions.

## Install in Termux

From the project root, back up the current files first, then extract the ZIP overlay into `~/Twice`:

```sh
cd ~/Twice || exit 1
mkdir -p backups/notification-fix-$(date +%Y%m%d-%H%M%S)
cp lib/data/notification_service.dart lib/data/inbox_controller.dart backups/notification-fix-$(date +%Y%m%d-%H%M%S)/ 2>/dev/null || true
unzip -o ~/storage/downloads/TWICE_NOTIFICATION_FIX.zip -d .
```

If you saved the ZIP somewhere else, change the path. Review the diff before committing:

```sh
git diff --check
git diff --stat
git diff -- lib/data/notification_service.dart lib/data/inbox_controller.dart
```

## Apply the database migration

Open Supabase Dashboard → SQL Editor and run the contents of:
`supabase/migrations/20261022150000_twice_notification_push_tokens.sql`

The table is only a token registry. It does not, by itself, deliver remote notifications.

## Required to receive notifications when the app is closed or killed

The existing `flutter_local_notifications` plugin can display local notifications while app code is running. Supabase Realtime is not a reliable background push transport, and a local notification does not wake a killed app. Real remote delivery requires Firebase Cloud Messaging (FCM), including:

1. A Firebase project with the Android app package matching Twice.
2. `google-services.json` and Firebase Gradle/plugin setup.
3. `firebase_core` and `firebase_messaging` in `pubspec.yaml`, initialized before app startup.
4. Registering/refreshing each signed-in user's FCM token in `public.device_push_tokens`, and deleting it on logout.
5. A trusted server-side sender (Supabase Edge Function using FCM HTTP v1 service-account credentials stored as Edge Function secrets, or another secure server). Never put service-account credentials in the Flutter app or Git repository.
6. A server-side event path for `notifications` and `messages`, with payloads containing only the recipient's relevant event and safe display fields.

The repository archive available for this patch does not include a Firebase project configuration or service-account credentials, so this bundle deliberately does not pretend that remote FCM delivery is already enabled.

## Replying from a phone notification

A true inline-reply action requires additional Android notification-action handling plus a secure, authenticated message-send path and conversation authorization. Do not send chat messages from an unauthenticated FCM function using a service-role key without validating the recipient and conversation membership. This bundle fixes local notification tap routing, but does not claim inline reply is configured.

## Notification tap routing in the app shell

The shell should set `NotificationService.instance.onTap` after initialization. Recommended behavior: open `MessagesPage` for `message` events; open the notifications inbox for other event types. Use `event.conversationId` / `event.postId` / `event.storyId` to navigate to the specific destination where supported.

## Verify

Run formatting/analyzer/build using your normal GitHub Actions workflow. Termux can run `git diff --check`; do not rely on local Android builds if your project uses GitHub Actions for Flutter builds.
