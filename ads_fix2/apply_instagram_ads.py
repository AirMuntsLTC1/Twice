#!/usr/bin/env python3
"""Adds the play-services-ads dependency that the custom Kotlin ad layout needs.

Run from the project root:  python3 ads_fix2/apply_instagram_ads.py
Backs the file up first; running it twice is harmless.
"""
import os
import shutil
import sys
import time

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
path = os.path.join(ROOT, "android", "app", "build.gradle.kts")
if not os.path.isfile(path):
    sys.exit("ERROR: %s not found. Run from the Twice project root." % path)

with open(path, encoding="utf-8") as fh:
    text = fh.read()

if "play-services-ads" in text:
    print("build.gradle.kts: already has play-services-ads - nothing to do")
    sys.exit(0)

anchor = 'flutter {\n    source = "../.."\n}'
if text.count(anchor) != 1:
    sys.exit(
        "ERROR: could not find the flutter { source = \"../..\" } block in "
        "build.gradle.kts. Nothing changed. Send me that file."
    )

block = (
    "dependencies {\n"
    "    // Compiles the custom Instagram-style native ad layout "
    "(NativeAdView / MediaView).\n"
    "    // Gradle still picks the newer version the google_mobile_ads plugin uses.\n"
    '    implementation("com.google.android.gms:play-services-ads:23.0.0")\n'
    "}\n\n"
)
backup = "%s.bak.ads2.%s" % (path, time.strftime("%Y%m%d_%H%M%S"))
shutil.copy2(path, backup)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text.replace(anchor, block + anchor))
print("patched build.gradle.kts (backup: %s)" % os.path.basename(backup))
