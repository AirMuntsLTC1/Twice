#!/usr/bin/env python3
"""Applies the Twice ads fix to lib/main.dart and lib/videos_screen.dart.

Usage (from the project root):   python3 ads_fix/apply_ads_fix.py
Safe by design: every edit is an exact-match replacement. If ANY anchor is
missing the script stops BEFORE writing anything, and every file it changes is
backed up first. Running it twice is harmless.
"""
import os
import shutil
import sys
import time

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
STAMP = time.strftime("%Y%m%d_%H%M%S")

MAIN = [
    (
        """                  onCommentChanged: () {
                    if (mounted) setState(() {});
                  },
                ),
                const SearchPage(),""",
        """                  onCommentChanged: () {
                    if (mounted) setState(() {});
                  },
                  adsActive: selected == 0,
                ),
                const SearchPage(),""",
    ),
    (
        """    required this.onCommentChanged,
    required this.onOpenComposer,
  });

  final GlobalKey<StoryStripState> storyStripKey;""",
        """    required this.onCommentChanged,
    required this.onOpenComposer,
    this.adsActive = true,
  });

  /// False while another tab is on screen, so native ad views are detached.
  final bool adsActive;

  final GlobalKey<StoryStripState> storyStripKey;""",
    ),
    (
        """                ? FeedNativeAdCard(
                    key: ValueKey('ad-slot-${entry.adSlot}'),
                    slot: entry.adSlot!,
                  )""",
        """                ? FeedNativeAdCard(
                    key: ValueKey('ad-slot-${entry.adSlot}'),
                    placement: AdPlacement.feed,
                    slot: entry.adSlot!,
                    active: adsActive,
                  )""",
    ),
]

VIDEOS = [
    (
        """  bool _appResumed = true;
  String? _error;
  int _index = 0;
""",
        """  bool _appResumed = true;
  String? _error;
  int _index = 0;

  // --- sponsored pages -----------------------------------------------------
  // Slots whose ad could not be loaded are left out of the pager, so the user
  // never lands on an empty black page.
  final Set<int> _deadAdSlots = <int>{};
  final Set<int> _prefetchingAds = <int>{};
  List<FeedEntry<SocialPost>> _entries = <FeedEntry<SocialPost>>[];
  bool _adsPrimed = false;

  /// Loads the ads that are 1-3 pages ahead, long before the user gets there.
  void _prefetchAdsAhead(int page) {
    if (!widget.active) return;
    final entries = _entries;
    for (var i = page + 1; i <= page + 3 && i < entries.length; i++) {
      final entry = entries[i];
      if (!entry.isAd) continue;
      final slot = entry.adSlot!;
      if (_deadAdSlots.contains(slot) || !_prefetchingAds.add(slot)) continue;
      TwiceAds.prefetch(AdPlacement.videos, slot).then((ok) {
        _prefetchingAds.remove(slot);
        if (!ok) _skipDeadAd(slot);
      });
    }
  }

  /// No ad for [slot]: drop its page. Pages behind the user are never touched,
  /// so the video on screen can't change under their finger.
  void _skipDeadAd(int slot) {
    if (!mounted || _deadAdSlots.contains(slot)) return;
    final adPage = _entries.indexWhere((e) => e.isAd && e.adSlot == slot);
    final current = _pager.hasClients ? (_pager.page ?? 0).round() : 0;
    if (adPage < 0 || adPage < current) return;
    setState(() => _deadAdSlots.add(slot));
    if (adPage == current) {
      // The ad page vanished and the next video now sits at this index.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || current >= _entries.length) return;
        if (_entries[current].isAd) return;
        final postIndex =
            _entries.take(current + 1).where((e) => !e.isAd).length - 1;
        _onPage(postIndex);
      });
    }
  }
""",
    ),
    (
        """        _posts
          ..clear()
          ..addAll(rows.map(SocialPost.new));
        _index = 0;""",
        """        _posts
          ..clear()
          ..addAll(rows.map(SocialPost.new));
        _adsPrimed = false;
        _index = 0;""",
    ),
    (
        """      final entries = interleaveAds<SocialPost>(
        _posts, interval: 5, maxAds: TwiceAdConfig.maxAdSlots,
      );
      body = PageView.builder(
        scrollDirection: Axis.vertical,
        controller: _pager,
        itemCount: entries.length,
        onPageChanged: (page) {
          final entry = entries[page];
          if (entry.isAd) {""",
        """      final entries = interleaveAds<SocialPost>(
        _posts,
        interval: TwiceAdConfig.videoInterval,
        maxAds: TwiceAdConfig.maxAdSlots,
        skipSlots: _deadAdSlots,
      );
      _entries = entries;
      if (!_adsPrimed) {
        _adsPrimed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _prefetchAdsAhead(0);
        });
      }
      body = PageView.builder(
        scrollDirection: Axis.vertical,
        controller: _pager,
        itemCount: entries.length,
        onPageChanged: (page) {
          if (page >= entries.length) return;
          final entry = entries[page];
          _prefetchAdsAhead(page);
          if (entry.isAd) {""",
    ),
    (
        """          if (entry.isAd) {
            return ColoredBox(
              color: Colors.black,
              child: Center(
                child: SingleChildScrollView(
                  child: FeedNativeAdCard(
                    key: ValueKey<String>('video-ad-${entry.adSlot}'),
                    slot: entry.adSlot!,
                  ),
                ),
              ),
            );
          }""",
        """          if (entry.isAd) {
            // Full-page sponsored page. No nested scroll view: the pager owns
            // every vertical drag (ScrollThrough forwards drags that start on
            // the native ad), and "Next video" is a guaranteed way out.
            return FeedNativeAdCard(
              key: ValueKey<String>('video-ad-${entry.adSlot}'),
              placement: AdPlacement.videos,
              slot: entry.adSlot!,
              fullPage: true,
              active: widget.active,
              topInset: top + 52,
              onUnavailable: () => _skipDeadAd(entry.adSlot!),
              onContinue: _next,
            );
          }""",
    ),
]

TARGETS = {
    os.path.join("lib", "main.dart"): MAIN,
    os.path.join("lib", "videos_screen.dart"): VIDEOS,
}


def plan():
    out = {}
    for rel, edits in TARGETS.items():
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            sys.exit("ERROR: %s not found. Run this from the Twice project root." % path)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        original = text
        for number, (old, new) in enumerate(edits, 1):
            if new in text:
                print("  %s edit %d: already applied" % (rel, number))
                continue
            count = text.count(old)
            if count != 1:
                sys.exit(
                    "ERROR: %s edit %d: expected 1 match, found %d.\n"
                    "Nothing was changed. Your file differs from the one I "
                    "inspected - send me the current file." % (rel, number, count)
                )
            text = text.replace(old, new)
            print("  %s edit %d: ok" % (rel, number))
        out[path] = (original, text)
    return out


def main():
    print("Planning edits in %s" % ROOT)
    changes = plan()
    for path, (original, text) in changes.items():
        if original == text:
            continue
        backup = "%s.bak.ads.%s" % (path, STAMP)
        shutil.copy2(path, backup)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print("patched %s (backup: %s)" % (path, os.path.basename(backup)))
    print("Done.")


if __name__ == "__main__":
    main()
