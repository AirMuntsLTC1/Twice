Feed scroll-jump fix: ad cards now start in their FINAL size (loaded or failed),
so the list never shifts when you scroll up past an ad slot.

  cd ~/Twice
  cp --parents lib/ads/*.dart ~/twice_ads2_backup/
  unzip -o ~/storage/downloads/Twice-Feed-Scroll-Fix.zip
  flutter analyze lib/ads
