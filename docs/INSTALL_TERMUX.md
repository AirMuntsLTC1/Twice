# Twice → Instagram-style Update (Termux)

This package fixes:

1. **Messages inbox** – real profile pictures, display names, last-message preview, unread blue dots & timestamps (no more generic “Conversation”).
2. **Chat thread** – Instagram bubbles, sender avatars, photo/video send, live realtime updates.
3. **Skeleton shimmer** – FB/IG style loading for feed + inbox + chat (no spinner flash).
4. **Interaction icons** – heart / comment / share / save match Instagram.
5. **Unread badges** – message count + notification count on the shell.
6. **Cache / boot timing** – offline-first feed, deferred Supabase boot, quiet resume refresh.
7. **Expanded C++ native** – resize, CRC32, frame-skip helpers for smooth video.
8. **Supabase SQL** – message notifications, unread RPC, realtime on `messages`.

---

## 1. Unzip into your project

```bash
cd ~/Twice   # or wherever your project lives
# backup first
cp -a lib lib.bak.$(date +%Y%m%d_%H%M%S)

# unzip the update (adjust path if needed)
unzip -o ~/storage/downloads/Twice-Instagram-Update.zip -d /tmp/twice-ig
# or if you already have the folder:
# UPDATE=/path/to/Twice-Instagram-Update
```

Copy files:

```bash
UPDATE=/tmp/twice-ig/Twice-Instagram-Update   # change if needed

# Widgets
mkdir -p lib/widgets
cp -f $UPDATE/lib/widgets/skeleton.dart lib/widgets/
cp -f $UPDATE/lib/widgets/ig_icons.dart lib/widgets/

# Messages (full page)
cp -f $UPDATE/lib/messages_page.dart lib/

# Inbox controller
cp -f $UPDATE/lib/data/inbox_controller.dart lib/data/

# Native
cp -f $UPDATE/android/app/src/main/cpp/twice_native.cpp android/app/src/main/cpp/
cp -f $UPDATE/android/app/src/main/cpp/CMakeLists.txt android/app/src/main/cpp/

# SQL (keep for later)
mkdir -p supabase/migrations
cp -f $UPDATE/supabase/migrations/20261021180000_twice_instagram_messaging.sql supabase/migrations/
```

---

## 2. Patch `lib/data/social_repository.dart`

Open `lib/data/social_repository.dart` and:

1. Add at the top if missing:
   ```dart
   import 'dart:io';
   import 'package:path/path.dart' as p;
   ```

2. **Replace** the existing `conversations()`, `messages()`, `sendMessage()` methods with the ones in:
   `lib/data/social_repository_chat_patch.dart`  
   (uncomment the block and paste into the class).

   Key new methods:
   - `conversationsDetailed()`
   - `messagesDetailed()`
   - `sendMediaMessage()`

---

## 3. Wire MessagesPage in `lib/main.dart`

1. Add import:
   ```dart
   import 'messages_page.dart';
   import 'widgets/skeleton.dart';
   import 'widgets/ig_icons.dart';
   import 'data/inbox_controller.dart';
   ```

2. Wherever you currently push `MessagesPage()` (search for `MessagesPage`), keep using it — the new file is a drop-in with the same class name.

3. **Skeleton on boot** – in `TwiceShell` / feed body, while `loading == true` show:
   ```dart
   if (loading) return const FeedSkeleton();
   ```
   instead of a centered `CircularProgressIndicator`.

4. **Unread badge on Messages icon** – wrap the messenger icon with:
   ```dart
   ListenableBuilder(
     listenable: InboxController.instance,
     builder: (_, __) {
       final n = InboxController.instance.messageUnread;
       return Badge(
         isLabelVisible: n > 0,
         label: Text('$n'),
         child: const IgMessenger(),
       );
     },
   )
   ```

5. Call `InboxController.instance.start()` after the user is signed in (inside `TwiceShell.initState` or when session becomes non-null). Call `.stop()` on sign-out.

6. **IG action row under posts** – replace the old IconButtons with:
   ```dart
   IgActionRow(
     liked: post.liked,
     saved: post.saved,
     likeCount: post.likes,
     onLike: () => _toggleLike(post),
     onComment: () => _openComments(post),
     onShare: () => _share(post),
     onSave: () => _toggleSave(post),
   )
   ```

7. Same `IgActionRow(vertical: true, ...)` on the **Videos** side rail.

---

## 4. Run the SQL migration (required)

1. Open Supabase Dashboard → SQL Editor.
2. Paste the full contents of  
   `supabase/migrations/20261021180000_twice_instagram_messaging.sql`
3. Run.
4. Confirm:
   - Function `twice_unread_conversation_count` exists.
   - Trigger `twice_message_notify` exists on `messages`.
   - Realtime publication includes `messages`.

---

## 5. Rebuild in Termux / GitHub Actions

```bash
# local debug (Termux with Flutter)
flutter pub get
flutter build apk --debug

# or push and let the existing GitHub Actions workflow build the release APK
```

If you use the GitHub workflow, make sure `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` secrets are still set.

---

## 6. Quick test checklist

| Check | Expected |
|-------|----------|
| Open Messages | Avatars + real names + last text + time |
| Unread message | Blue dot + bold preview |
| Open chat | Bubbles, other user avatar on left |
| Send text | Instant bubble, appears for other user |
| Send photo / video | Uploads to `chat-media`, shows in bubble |
| Feed first open | Skeleton shimmer, then posts |
| Like / comment / share / save icons | Match Instagram outlines |
| Video tab side icons | Vertical Instagram-style |

---

## Files in this zip

```
Twice-Instagram-Update/
├── lib/
│   ├── messages_page.dart          ← full IG inbox + chat
│   ├── data/
│   │   ├── inbox_controller.dart   ← unread badges + realtime
│   │   └── social_repository_chat_patch.dart
│   └── widgets/
│       ├── skeleton.dart           ← shimmer loaders
│       └── ig_icons.dart           ← heart/comment/share/save
├── android/app/src/main/cpp/
│   ├── twice_native.cpp            ← expanded native helpers
│   └── CMakeLists.txt
├── supabase/migrations/
│   └── 20261021180000_twice_instagram_messaging.sql
├── docs/
│   └── INSTALL_TERMUX.md           ← this file
└── scripts/
    └── apply_update.sh             ← one-shot copy helper
```
