TWICE - ADMOB NATIVE IN-FEED VIDEO ADS
======================================

INSTALL (Termux)
  cd ~/Twice
  unzip -o ~/storage/downloads/twice-ads-update.zip
  flutter pub get
  flutter analyze
  flutter run            # debug = Google TEST ads (safe)

PUSH
  git add -A
  git commit -m "Add AdMob native in-feed video ads"
  git push

WHAT CHANGED
  NEW   lib/ads/ad_config.dart        IDs, interval (6), test/live switch
  NEW   lib/ads/feed_entries.dart     interleaveAds(): ad after every N posts
  NEW   lib/ads/ad_manager.dart       init, preload, pool, muted-start options
  NEW   lib/ads/native_ad_card.dart   skeleton -> fade-in card, "Sponsored"
  EDIT  lib/main.dart                 3 imports, TwiceAds.init(), FeedPage
  EDIT  pubspec.yaml                  google_mobile_ads: ^6.0.0
  EDIT  android/.../AndroidManifest.xml  AdMob App ID + AD_ID permission

TEST vs LIVE
  Debug/profile builds use Google's test unit. Release builds (and your GitHub
  Actions APK) use your live unit ca-app-pub-2388362234538140/2313557661.
  Never tap your own live ads. To test live ads safely, put your device hash
  (printed in logcat) in TwiceAdConfig.testDeviceIds.

TUNING (lib/ads/ad_config.dart)
  feedInterval = 6, maxAdSlots = 12, adHeight = 380
