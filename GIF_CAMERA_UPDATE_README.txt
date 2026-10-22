TWICE CHAT CAMERA + GIPHY PATCH
================================

Files overlaid:
- Twice/lib/messages_page.dart
- Twice/lib/data/social_repository.dart (only infer image MIME type from file extension)
- Twice/pubspec.yaml

Changes:
- Composer camera button launches the phone camera via image_picker; it no longer opens the custom gallery.
- Existing image/media button still opens the existing custom media picker.
- Replaced the video-camera composer icon with a GIF icon.
- GIF picker has a top search field, grid layout matching the dark custom media picker, GIPHY trending/search, and sends immediately when one GIF is tapped.
- GIF downloads and preview thumbnails are cached under the app's persistent support directory. Cached trending results and preview files can be reused offline. Sending a GIF stores the original animated .gif file; Flutter's image renderer animates GIF frames.

Install from Termux:
  cd ~
  unzip -o ~/storage/downloads/Twice-GIF-Camera-Update.zip
  cd ~/Twice
  git diff --check
  flutter analyze

Then inspect the diff, commit and push to trigger the existing GitHub Actions APK workflow:
  git diff --stat
  git add lib/messages_page.dart pubspec.yaml
  git commit -m "Add chat GIF picker and native camera action"
  git push origin main

Notes:
- This patch does not change Supabase schema or repository send functions.
- The existing GIF send path is reused. The media upload now sets `image/gif` for `.gif` files (and the correct image MIME type for PNG/WebP) instead of incorrectly labeling every image as JPEG; animated GIF bytes are uploaded unchanged.
- The new image_picker dependency will be resolved by the existing CI `flutter pub get` step. No Gradle/SDK/NDK versions are changed.
- GIPHY API key is embedded as supplied. For a public production app, use a restricted/managed API key where possible.
