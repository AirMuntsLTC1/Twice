import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../widgets/skeleton.dart';
import 'ad_config.dart';
import 'ad_manager.dart';

/// In-feed native video ad that sits in the same list as organic posts.
///
/// Behaviour:
///  * Starts loading while it is still well off-screen (the feed's cache extent
///    builds it ~2 posts early) and warms the NEXT ad slot once this one is
///    mostly visible, so ads are ready before they scroll in.
///  * Shows a post-shaped skeleton, then cross-fades to the ad. Nothing
///    jumps: skeleton and ad share the same fixed height.
///  * If there is no fill, the row collapses smoothly to nothing.
///  * Video starts muted (set in the ad request). Sound only turns on if the
///    user taps the unmute control on the ad itself.
///  * "Sponsored" label + AdMob's own "Ad" badge stay visible (policy).
class FeedNativeAdCard extends StatefulWidget {
  const FeedNativeAdCard({super.key, required this.slot});

  final int slot;

  @override
  State<FeedNativeAdCard> createState() => _FeedNativeAdCardState();
}

class _FeedNativeAdCardState extends State<FeedNativeAdCard> {
  NativeAd? _ad;
  bool _failed = false;
  bool _revealed = false;
  bool _warmedNext = false;
  Timer? _revealTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ad = await TwiceAds.acquire(widget.slot);
    if (!mounted) {
      if (ad != null) TwiceAds.release(widget.slot);
      return;
    }
    if (ad == null) {
      setState(() => _failed = true);
      return;
    }
    TwiceAds.markMounted(widget.slot, true);
    setState(() => _ad = ad);
    // Give the platform view a moment to draw its first frame, then fade the
    // skeleton away. Avoids a white flash.
    _revealTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted) setState(() => _revealed = true);
    });
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    if (_ad != null) {
      TwiceAds.markMounted(widget.slot, false);
      TwiceAds.release(widget.slot);
      _ad = null;
    }
    super.dispose();
  }

  void _onVisibility(VisibilityInfo info) {
    if (!mounted) return;
    // Once this ad is mostly on screen, warm the next slot in the background.
    if (!_warmedNext && info.visibleFraction >= 0.5) {
      _warmedNext = true;
      unawaited(TwiceAds.prefetch(widget.slot + 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: ValueKey('twice-native-ad-${widget.slot}'),
      onVisibilityChanged: _onVisibility,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _failed
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 6, 12, 6),
                      child: Text(
                        'Sponsored',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFA8A8A8),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: TwiceAdConfig.adHeight,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_ad != null) AdWidget(ad: _ad!),
                          // Skeleton sits ON TOP and fades out. (Fading the
                          // Flutter skeleton is smooth; fading a native
                          // platform view directly is not.)
                          IgnorePointer(
                            ignoring: _revealed,
                            child: AnimatedOpacity(
                              opacity: _revealed ? 0 : 1,
                              duration: const Duration(milliseconds: 380),
                              curve: Curves.easeOut,
                              child: const _AdSkeleton(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Post-shaped placeholder: avatar + name line, big media block, text lines.
class _AdSkeleton extends StatelessWidget {
  const _AdSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF000000),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                TwiceSkeleton(width: 32, height: 32, borderRadius: 16),
                SizedBox(width: 10),
                TwiceSkeleton(width: 120, height: 12),
              ],
            ),
          ),
          Expanded(
            child: TwiceSkeleton(
              height: double.infinity,
              borderRadius: 0,
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: TwiceSkeleton(width: 200, height: 12),
          ),
        ],
      ),
    );
  }
}
