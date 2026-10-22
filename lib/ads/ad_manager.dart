import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_config.dart';

/// Where an ad is shown. Each placement has its OWN ads: the Home feed and the
/// Videos tab can never fight over the same native view (the old shared pool
/// did exactly that and left blank / stuck ads).
enum AdPlacement { feed, videos }

class _AdSlot {
  _AdSlot(this.ad) : loadedAt = DateTime.now();
  final NativeAd ad;
  final DateTime loadedAt;

  /// Number of widgets currently holding this ad. A NativeAd can be attached
  /// to exactly ONE AdWidget, so this is 0 or 1.
  int leases = 0;

  bool get stale => DateTime.now().difference(loadedAt) > TwiceAdConfig.adTtl;
}

/// Loads, preloads and leases native ads.
///
/// Architecture:
///  * [prefetch]    loads an ad in the background and keeps it ready.
///  * [obtainLease] hands the ad to ONE widget; nobody else can mount it.
///  * [release]     gives it back; idle ads are evicted oldest-first.
/// The widget decides WHEN the native view is attached (only near the
/// viewport); the manager only decides WHAT ad it gets.
class TwiceAds {
  TwiceAds._();

  static bool _initialized = false;
  static Future<bool>? _initFuture;

  static final Map<String, _AdSlot> _slots = <String, _AdSlot>{};
  static final Map<String, Future<_AdSlot?>> _loading =
      <String, Future<_AdSlot?>>{};
  static final Map<String, DateTime> _failedAt = <String, DateTime>{};

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static String _key(AdPlacement p, int slot) => '${p.name}:$slot';

  // ------------------------------------------------------------------ init

  /// Call once at startup (fire and forget). Also warms feed slot 0.
  static Future<void> init() async {
    if (!await _ensureInit()) return;
    unawaited(prefetch(AdPlacement.feed, 0));
  }

  static Future<bool> _ensureInit() {
    if (!supported) return Future<bool>.value(false);
    if (_initialized) return Future<bool>.value(true);
    final existing = _initFuture;
    if (existing != null) return existing;

    final completer = Completer<bool>();
    _initFuture = completer.future;
    () async {
      var ok = false;
      try {
        ok = await _updateConsentAndInitialize();
      } catch (e) {
        debugPrint('TwiceAds initialization error: $e');
      }
      _initialized = ok;
      if (!ok) _initFuture = null; // allow a retry later
      completer.complete(ok);
    }();
    return completer.future;
  }

  /// UMP consent (EEA/UK etc.), then MobileAds.initialize.
  static Future<bool> _updateConsentAndInitialize() async {
    final consentDone = Completer<void>();
    try {
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () async {
          try {
            ConsentForm.loadAndShowConsentFormIfRequired((formError) {
              if (formError != null) {
                debugPrint('TwiceAds UMP form: ${formError.message}');
              }
              if (!consentDone.isCompleted) consentDone.complete();
            });
          } catch (e) {
            debugPrint('TwiceAds UMP form threw: $e');
            if (!consentDone.isCompleted) consentDone.complete();
          }
        },
        (FormError error) {
          debugPrint('TwiceAds UMP update failed: ${error.message}');
          if (!consentDone.isCompleted) consentDone.complete();
        },
      );
    } catch (e) {
      debugPrint('TwiceAds UMP request threw: $e');
      if (!consentDone.isCompleted) consentDone.complete();
    }

    await consentDone.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {},
    );

    var canRequest = true;
    try {
      canRequest = await ConsentInformation.instance.canRequestAds();
    } catch (_) {
      canRequest = true;
    }
    if (!canRequest) {
      debugPrint('TwiceAds: consent does not allow ad requests.');
      return false;
    }

    try {
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(testDeviceIds: TwiceAdConfig.testDeviceIds),
      );
      await MobileAds.instance.initialize();
      return true;
    } catch (e) {
      debugPrint('TwiceAds MobileAds.initialize failed: $e');
      return false;
    }
  }

  // ----------------------------------------------------------- public API

  /// Loads the ad for [slot] in the background. Returns true when an ad is
  /// ready (or already held), false when there is no fill / no network.
  static Future<bool> prefetch(AdPlacement placement, int slot) async {
    if (slot < 0 || slot >= TwiceAdConfig.maxAdSlots) return false;
    return (await _obtain(placement, slot)) != null;
  }

  /// True when the last request for this slot failed recently.
  static bool recentlyFailed(AdPlacement placement, int slot) {
    final t = _failedAt[_key(placement, slot)];
    return t != null &&
        DateTime.now().difference(t) < TwiceAdConfig.failureBackoff;
  }

  /// Gives ONE widget exclusive use of the ad for [slot].
  /// Returns null when there is no ad (the caller should collapse / skip).
  static Future<NativeAd?> obtainLease(AdPlacement placement, int slot) async {
    final now = _tryLease(placement, slot);
    if (now != null) return now;
    final loaded = await _obtain(placement, slot);
    if (loaded == null) return null;
    return _tryLease(placement, slot);
  }

  static void release(AdPlacement placement, int slot) {
    final s = _slots[_key(placement, slot)];
    if (s == null) return;
    if (s.leases > 0) s.leases--;
    _evict(placement);
  }

  // ------------------------------------------------------------- internals

  static NativeAd? _tryLease(AdPlacement placement, int slot) {
    final key = _key(placement, slot);
    final s = _slots[key];
    if (s == null || s.leases > 0) return null;
    if (s.stale) {
      _slots.remove(key);
      _safeDispose(s.ad);
      return null;
    }
    s.leases++;
    return s.ad;
  }

  static Future<_AdSlot?> _obtain(AdPlacement placement, int slot) {
    final key = _key(placement, slot);
    final existing = _slots[key];
    if (existing != null && (!existing.stale || existing.leases > 0)) {
      return Future<_AdSlot?>.value(existing);
    }
    if (existing != null) {
      _slots.remove(key);
      _safeDispose(existing.ad);
    }
    if (recentlyFailed(placement, slot)) return Future<_AdSlot?>.value(null);
    // Block body on purpose: an arrow function would return the removed
    // future itself and make whenComplete() wait on itself forever.
    return _loading[key] ??= _load(placement, slot).whenComplete(() {
      _loading.remove(key);
    });
  }

  static Future<_AdSlot?> _load(AdPlacement placement, int slot) async {
    if (!await _ensureInit()) return null;

    final key = _key(placement, slot);
    final done = Completer<_AdSlot?>();

    final ad = NativeAd(
      adUnitId: TwiceAdConfig.nativeUnitId,
      request: const AdRequest(),
      nativeTemplateStyle: _darkTemplate(),
      nativeAdOptions: NativeAdOptions(
        videoOptions: VideoOptions(
          startMuted: true,
          clickToExpandRequested: false,
          customControlsRequested: false,
        ),
        mediaAspectRatio: MediaAspectRatio.any,
      ),
      listener: NativeAdListener(
        onAdLoaded: (loaded) {
          final slotEntry = _AdSlot(loaded as NativeAd);
          final old = _slots[key];
          if (old != null && old.leases > 0) {
            // Someone is already showing an ad in this slot; keep theirs.
            _safeDispose(loaded);
            if (!done.isCompleted) done.complete(old);
            return;
          }
          if (old != null) _safeDispose(old.ad);
          _slots[key] = slotEntry;
          _failedAt.remove(key);
          if (!done.isCompleted) done.complete(slotEntry);
          _evict(placement);
        },
        onAdFailedToLoad: (failedAd, error) {
          debugPrint(
            'TwiceAds $key failed: code=${error.code} '
            'domain=${error.domain} message=${error.message}',
          );
          _safeDispose(failedAd);
          _failedAt[key] = DateTime.now();
          if (!done.isCompleted) done.complete(null);
        },
      ),
    );

    try {
      await ad.load();
    } catch (e) {
      debugPrint('TwiceAds $key load threw: $e');
      _safeDispose(ad);
      _failedAt[key] = DateTime.now();
      if (!done.isCompleted) done.complete(null);
    }

    return done.future.timeout(
      TwiceAdConfig.loadTimeout,
      onTimeout: () {
        debugPrint('TwiceAds $key timed out');
        _failedAt[key] = DateTime.now();
        return null;
      },
    );
  }

  static void _evict(AdPlacement placement) {
    final mine = _slots.entries
        .where((e) => e.key.startsWith('${placement.name}:'))
        .toList();
    if (mine.length <= TwiceAdConfig.maxPooledPerPlacement) return;
    final idle = mine.where((e) => e.value.leases == 0).toList()
      ..sort((a, b) => a.value.loadedAt.compareTo(b.value.loadedAt));
    var count = mine.length;
    for (final e in idle) {
      if (count <= TwiceAdConfig.maxPooledPerPlacement) break;
      _slots.remove(e.key);
      _safeDispose(e.value.ad);
      count--;
    }
  }

  static void _safeDispose(Ad ad) {
    try {
      ad.dispose();
    } catch (_) {}
  }

  /// Black / white / blue styling that matches Twice's dark UI.
  static NativeTemplateStyle _darkTemplate() {
    const black = Color(0xFF000000);
    const blue = Color(0xFF0095F6);
    const muted = Color(0xFFA8A8A8);
    return NativeTemplateStyle(
      templateType: TemplateType.medium,
      mainBackgroundColor: black,
      cornerRadius: 8,
      callToActionTextStyle: NativeTemplateTextStyle(
        textColor: Colors.white,
        backgroundColor: blue,
        style: NativeTemplateFontStyle.bold,
        size: 14,
      ),
      primaryTextStyle: NativeTemplateTextStyle(
        textColor: Colors.white,
        backgroundColor: black,
        style: NativeTemplateFontStyle.bold,
        size: 14,
      ),
      secondaryTextStyle: NativeTemplateTextStyle(
        textColor: muted,
        backgroundColor: black,
        style: NativeTemplateFontStyle.normal,
        size: 12,
      ),
      tertiaryTextStyle: NativeTemplateTextStyle(
        textColor: muted,
        backgroundColor: black,
        style: NativeTemplateFontStyle.normal,
        size: 12,
      ),
    );
  }
}
