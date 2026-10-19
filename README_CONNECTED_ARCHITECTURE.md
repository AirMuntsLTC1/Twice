# Twice — Supabase integration update

This update removes the hard-coded sample feed, sample story strip, demo activity rows, and placeholder profile identity from the active UI. It introduces a Supabase repository boundary at `lib/data/social_repository.dart` and connects the primary UI flows to the existing schema.

## Connected in this update

- Existing Google/Supabase authentication remains in place.
- Profile bootstrap uses the authenticated user and existing `public.profiles` row; display name and `@username` are loaded from Supabase.
- Profile editing updates `display_name`, `username`, and `bio` with client-side username validation.
- Feed reads real `posts`, author profiles, media rows, and likes under the database's RLS policies.
- Like/unlike updates `post_likes` with optimistic UI and refresh-on-error.
- Composer publishes real posts; selected photos/videos upload to the private `post-media` bucket at `user_id/post_id/filename`, and media metadata is written to `post_media`.
- Private post media is resolved through short-lived signed URLs.
- Search returns real profiles and posts.
- Comments read/write `public.comments`.
- Activity reads `public.notifications`.
- Existing conversations and messages are read from `conversation_members`, `conversations`, and `messages`; a direct conversation can be started from a user search result.
- Native C++ library and Android build configuration are retained.

## Not represented as finished

This is a source integration pass, not a claim of production certification. I could not run Flutter/Dart analysis or an Android build in this environment. The GitHub Actions workflow should be used to compile and test this exact source before installing it.

The following still need implementation/verification in subsequent passes: story creation/viewing and expiry cleanup, avatar upload and profile photo picker, notification generation and read-state updates, live realtime subscriptions, media attachments in chat, pagination/infinite scrolling, post deletion/editing and save-state display, complete follow-request approval UI, privacy settings UI, and end-to-end RLS testing with multiple real accounts. Chat-media policy migration 005 is included but not automatically applied.

## Storage object conventions

- Post media: `post-media/{auth.uid}/{post_uuid}/{filename}`. `post_media.media_url` stores the object path, not a public URL.
- Story media (for a future story uploader): `stories/{auth.uid}/{story_uuid}/{filename}`.
- Chat media (for a future attachment uploader): `chat-media/{uploader_uid}/{conversation_uuid}/{filename}`.
- Avatar bucket remains public by existing project configuration; avatar upload is not implemented in this update.

Never put the Supabase service-role key or access token in Flutter source. The mobile app uses only the publishable/anon client key and relies on RLS.

## Supabase migration

Migrations `001`–`004` were reported applied before this source bundle was prepared. Migration `005` changes chat-media read policy so any member of a conversation can read an object stored under that conversation's path, while writes/deletes remain uploader-folder restricted. Apply it only after reviewing the policy and confirming the object path convention:

```bash
cd ~/Twice
supabase db query --linked --output-format json "$(cat supabase/migrations/20261019000500_twice_chat_media_member_access.sql)"
```

## Validate

From GitHub Actions, run the existing workflow's `flutter analyze`, `flutter test`, and ARM64 release build. If it fails, send the complete failing step output; do not rotate toolchain versions to work around errors.
