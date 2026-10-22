TWICE INSTAGRAM-STYLE ADS (custom native layout)
================================================

INSTALL (Termux)
  cd ~/Twice
  mkdir -p ~/twice_ads2_backup
  cp --parents android/app/src/main/kotlin/com/twice/twice/MainActivity.kt \
      android/app/build.gradle.kts lib/ads/*.dart ~/twice_ads2_backup/
  unzip -o ~/storage/downloads/Twice-Ads-Instagram.zip
  python3 ads_fix2/apply_instagram_ads.py
  flutter analyze lib/ads
  git add -A && git commit -m "Instagram-style native ads" && git push

WHAT YOU GET
  * Each ad is drawn like a post: icon + name, "Sponsored" + "Ad" label,
    large photo/video, blue call-to-action bar, caption.
  * AdChoices icon stays visible (top right), as Google requires.
  * Every post slot and every video slot gets its OWN ad.
  * Short feeds still get one ad (after the last post/video).
  * Home feed: a grey line explains why an ad is missing
    (lib/ads/ad_config.dart -> showDiagnostics = false to turn it off).

ADMOB CONSOLE (important)
  Apps > Twice > Ad units > Twice_Video_Feed_Native > Edit
  Media type is "Video" only. Change it so it allows BOTH images and video.
  Video-only ads are far scarcer, so the unit gets little or no fill.
