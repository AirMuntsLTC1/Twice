TWICE CHAT FIX — "Telegram / Messenger style" chatroom
=======================================================

WHAT WAS WRONG
--------------
1. Black / blank thumbnails
   Chat images were drawn with NetworkImage keyed by a SIGNED URL. A new URL
   (new token) is created on every reload, so Flutter treated each reload as a
   brand-new image -> blank/black until it re-downloaded. Videos were fed to an
   image widget, so they never had a real thumbnail. The gallery picker also
   recreated its thumbnail futures on every tap (black flashes while selecting).
2. Chatroom constantly "refreshing"
   load() re-fetched messages + members + attachments + profiles + signed URLs
   (6+ requests) on every realtime event, every app resume, 1s after every
   media send, and from the Refresh button. The inbox also showed its skeleton
   every time you came back from a chat.

WHAT IS NEW
-----------
* Media is keyed by STORAGE PATH, cached on disk, painted from a local file
  (gapless, fixed-size placeholder, fade-in). It can never go black on reload.
* Video bubbles use the same poster engine as the feed (real frame + play icon).
* Chat opens INSTANTLY from memory/disk. No spinner (skeleton only the very
  first time ever).
* Delta sync: only messages newer than the last one are fetched, silently.
  Realtime inserts are applied in place - no refetch, no list rebuild.
* Optimistic sends confirmed with the saved row (no guessing, no fake 900ms
  timer). Failed sends show "tap to retry / hold to delete".
* Sends continue even if you leave the chat (session outlives the page).
* Auto gap-fill after any reconnect + a quiet safety-net sync every ~45s.
* Typing indicator, instant read receipts (via presence), "Active now".
* Pagination: latest 40 messages, older ones load as you scroll up
  (old code loaded the OLDEST 300 and could miss newer messages).
* "Jump to latest" button with new-message counter when scrolled up.
* Inbox: stale-while-revalidate, patched live from realtime, silent refresh.
* No banner/badge for messages in the chat you are already looking at.
* The Refresh button is gone - nothing needs it any more.

FILES IN THIS ZIP (paths are relative to ~/Twice)
------------------------------------------------
  lib/messages_page.dart            (replaced - inbox + chatroom UI)
  lib/data/chat_controller.dart     (replaced - chat session engine)
  lib/data/chat_repository.dart     (NEW - fast network layer)
  lib/data/chat_media.dart          (NEW - stable media resolver)
  lib/data/offline_media_cache.dart (replaced - 2 small helper methods added)
  lib/data/inbox_controller.dart    (replaced - activeConversationId added)

No SQL migration needed. No new packages needed. main.dart and
social_repository.dart are NOT touched.

INSTALL (Termux)
----------------
  cd ~/Twice
  mkdir -p ~/twice_chat_backup
  cp --parents lib/messages_page.dart lib/data/chat_controller.dart \
     lib/data/offline_media_cache.dart lib/data/inbox_controller.dart \
     ~/twice_chat_backup/

  cd ~ && unzip -o ~/storage/downloads/Twice-Chat-Fix.zip

  cd ~/Twice
  flutter pub get
  flutter analyze lib/messages_page.dart lib/data
  # then build / push as you normally do

ROLLBACK
--------
  cp -r ~/twice_chat_backup/lib/. ~/Twice/lib/
  rm ~/Twice/lib/data/chat_repository.dart ~/Twice/lib/data/chat_media.dart

OPTIONAL (logout)
-----------------
Call ChatController.resetAll(); from your sign-out code so no chat state is
kept in memory for the next account. (Sessions are already keyed per account.)
