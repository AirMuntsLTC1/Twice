# Twice notifications — production setup (minimal checklist)

## Already in the app (code)

- DB triggers create `public.notifications` rows (like, comment, reply, follow, message, story, save).
- In-app top banner + local tray via `NotificationService` + Realtime.
- FCM client: `PushNotificationService` registers tokens into `device_push_tokens`.
- Edge Function `twice-send-push` sends FCM HTTP v1 using a service account.

## Build fix (CI failure)

`flutter_local_notifications` requires **core library desugaring**.

`android/app/build.gradle.kts` must contain:

```kotlin
compileOptions {
    isCoreLibraryDesugaringEnabled = true
    ...
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

This pack overwrites that file with a clean version.

## One-time server setup (you must do these — secrets cannot be automated)

### 1. Run SQL (Supabase → SQL Editor)

Run if not already applied:

- `supabase/migrations/20261021000300_twice_inbox_notifications.sql` (triggers)
- `supabase/migrations/20261022130000_twice_notification_types_save.sql` (save type)
- `supabase/migrations/20261022150000_twice_notification_push_tokens.sql` (token table)

### 2. Firebase service account

Firebase Console → Project settings → Service accounts → Generate new private key.

Store JSON content as Supabase Edge Function secret:

```text
FIREBASE_SERVICE_ACCOUNT_JSON
```

Also ensure:

```text
TWICE_PUSH_WEBHOOK_SECRET   # long random string you invent
SUPABASE_SERVICE_ROLE_KEY   # auto in Edge Functions, or set explicitly
SUPABASE_URL                # auto in Edge Functions
```

### 3. Deploy Edge Function

From a machine with Supabase CLI linked (or Dashboard → Edge Functions → Deploy):

```bash
supabase functions deploy twice-send-push --no-verify-jwt
```

(`--no-verify-jwt` because Database Webhooks call with the shared secret header, not a user JWT.)

### 4. Database Webhook (the critical missing link)

Supabase Dashboard → Database → Webhooks → Create a new hook:

| Field | Value |
|-------|--------|
| Name | `twice-notifications-push` |
| Table | `public.notifications` |
| Events | **Insert** |
| Type | HTTP Request |
| Method | POST |
| URL | `https://jgqxvqlwnfywzoxbfkpk.supabase.co/functions/v1/twice-send-push` |
| HTTP Headers | `x-twice-push-secret: <same as TWICE_PUSH_WEBHOOK_SECRET>` |
| | `Content-Type: application/json` |

Without this webhook, FCM is never invoked when a notification row is inserted.

### 5. Android / Firebase app

- Package name must be `com.twice.twice`
- `android/app/google-services.json` present (already in repo)
- SHA-1 of the **debug** keystore used by GitHub Actions for FCM on debug builds

## Verify

1. Sign in on device → check `device_push_tokens` has a row for your user.
2. From another account: like a post / send a message.
3. Expect: in-app banner (if app open) + system notification (if background/killed after FCM is wired).
4. Tap notification → opens Messages or Activity depending on type.

## What this does NOT require you to do

- No service-role keys in Flutter
- No rebuilding the social schema
- No disabling RLS
