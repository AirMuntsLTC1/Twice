TWICE CONNECTIVITY / MEDIA / OFFLINE CACHE UPDATE
================================================

Files changed
-------------
- lib/main.dart
  * Media picker queries image and video assets separately and de-duplicates them.
  * Post comments render optimistically and stop waiting after a bounded timeout.
  * Video/image feed rendering supports persistent local file URIs.
- lib/data/social_repository.dart
  * Comment reads use an explicit comments -> profiles FK relation.
  * Comment requests have a 15-second timeout and expose non-network errors.
  * Offline comments are stored in the existing local outbox and replayed on launch.
  * Feed media and profile avatars are warmed into persistent app storage in the
    background; cached feed rows are updated to file:// URIs after successful downloads.
- lib/data/offline_media_cache.dart
  * New persistent media file cache with bounded image/video download sizes.
- pubspec.yaml / pubspec.lock
  * Declare http and path_provider as direct dependencies.
- supabase/migrations/20261021000100_twice_media_bucket_formats.sql
  * Allows common phone-captured formats in the private post-media and stories
    buckets while keeping each bucket private.

Apply the source update in Termux
---------------------------------
The full ZIP contains a top-level `Twice/` directory. From Termux run:

  unzip -o ~/storage/downloads/Twice-connected-fixes-full-project.zip -d ~

Then return to the project:

  cd ~/Twice

This overlays updated source files without deleting your existing Git history.
The archive intentionally omits generated build caches and Supabase's local
`.temp` metadata.

Supabase migration
------------------
The SQL migration is included but is NOT automatically executed by the Android
build workflow. Review and run
`supabase/migrations/20261021000100_twice_media_bucket_formats.sql`
in Supabase Dashboard -> SQL Editor if you want uploads of HEIC/HEIF/AVIF,
MOV/QuickTime, M4V, 3GP, and Matroska files. Existing JPG/PNG/WebP/GIF and
MP4/WebM uploads remain supported by the current bucket settings.

Build and verify
----------------
This environment did not have Flutter/Dart installed and cannot run a real
Android build or authenticate to your Supabase project. After applying the ZIP,
push the changes to your GitHub repository and inspect both GitHub Actions jobs:
`Build Android APK` and `Verify Dart code and tests`. If either job fails, send
the full log; do not assume the APK is validated until CI succeeds.

Offline behavior and limits
---------------------------
- Feed/profile/comment metadata is cached per signed-in account in SQLite.
- Up to 12 feed media items per refresh are warmed in the background, including
  video posters when available. Each video cache is capped at 80 MiB and each
  image/poster/avatar at 18 MiB; oversized or unavailable files remain online-only.
- A queued comment is shown immediately with an offline-pending label and retried
  when the signed-in app starts with connectivity.
- A permanent Supabase policy/schema error is shown to the user instead of being
  silently treated as a successful comment.
- Local cache is account-scoped; logging out purges that account's SQLite cache.
