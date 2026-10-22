TWICE ADS FIX - real AdMob ads, smooth scrolling, Videos-tab ad page
====================================================================

INSTALL (Termux)
  cd ~/Twice
  cp -a lib lib.bak.$(date +%Y%m%d_%H%M%S)        # optional extra backup
  unzip -o ~/storage/downloads/Twice-Ads-Fix.zip
  python3 ads_fix/apply_ads_fix.py
  git add -A && git commit -m "Fix ads: live only, no scroll lock" && git push

(unzip puts the 4 ad files into lib/ads/ ; the python script patches
 lib/main.dart and lib/videos_screen.dart in place and backs them up.)

WHAT CHANGED
  lib/ads/ad_config.dart       LIVE unit only. Google test units removed.
  lib/ads/ad_manager.dart      Separate ads for Home feed and Videos tab,
                               one owner per ad, preload + failure backoff.
  lib/ads/feed_entries.dart    Can leave out slots that have no fill.
  lib/ads/native_ad_card.dart  Scroll-through layer, attach only near screen,
                               full-page ad page with "Next video" button.
  lib/main.dart                FeedPage gets adsActive (3 small edits).
  lib/videos_screen.dart       Ad page rebuilt, ads preloaded 1-3 pages ahead,
                               empty ad pages are skipped (5 small edits).

NOTES
  * Never tap your own live ads (AdMob invalid-traffic policy).
  * A new ad unit can take hours/days to fill; no fill = no ad is shown.
  * Not built or run here (no Flutter SDK): build with your GitHub Action.
