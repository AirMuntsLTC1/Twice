import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_config.dart';

class _PoolEntry {
  _PoolEntry(this.ad) : loadedAt = DateTime.now();
  final NativeAd ad;
  final DateTime loadedAt;
  int refs = 0;
  bool isMounted = false;
  bool get stale => DateTime.now().difference(loadedAt) > TwiceAdConfig.adTtl;
}

/// Loads, preloads, pools and manages native ads for the feed.
///
/// Features:
///  * UMP Consent flow initialization with graceful offline fallback.
///  * Robust error diagnostics with human-readable error names without credential exposure.
///  * Duplicate-mount prevention for AdWidget in scrolling lists.
///  * Safe disposal and memory bounds.
class TwiceAds {
  TwiceAds._();

  static const int _maxPooled = 6;

  static bool _initialized = false;
  static Future<bool>? _initFuture;
  static final Map<int, _PoolEntry> _pool = {};
  static final Map<int, Future<_PoolEntry?>> _pending = {};
  static final Map<int, DateTime> _failedAt = {};

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Human-readable AdMob error codes for safe diagnostic logging.
  static String _adErrorCodeName(int code) {
    switch (code) {
      case 0:
        return 'INTERNAL_ERROR';
      case 1:
        return 'INVALID_REQUEST';
      case 2:
        return 'NETWORK_ERROR';
      case 3:
        return 'NO_FILL';
      default:
        return 'CODE_$code';
    }
  }

  /// Call once at startup (fire and forget). Also warms slot 0 so the first ad
  /// is already loaded by the time the user scrolls to it.
  static Future<void> init() async {
    if (!await _ensureInit()) return;
    unawaited(prefetch(0));
  }

  static Future<bool> _ensureInit() {
    if (!supported) return Future.value(false);
    if (_initialized) return Future.value(true);
    if (_initFuture != null) return _initFuture!;

    final completer = Completer<bool>();
    _initFuture = completer.future;

    () async {
      try {
        final success = await _updateConsentAndInitialize();
        _initialized = success;
        completer.complete(success);
      } catch (e) {
        debugPrint('TwiceAds initialization error: $e');
        _initialized = false;
        completer.complete(false);
      } finally {
        if (!_initialized) {
          // Allow retrying initialization on subsequent requests if it failed.
          _initFuture = null;
        }
      }
    }();

    return completer.future;
  }

  /// Requests UMP consent update, displays consent form if required, and then
  /// initializes the MobileAds SDK if allowed.
  static Future<bool> _updateConsentAndInitialize() async {
    final consentCompleter = Completer<void>();
    final params = ConsentRequestParameters();

    try {
      ConsentInformation.instance.requestConsentInfoUpdate(
        params,
        () async {
          try {
            ConsentForm.loadAndShowConsentFormIfRequired((formError) async {
              if (formError != null) {
                debugPrint(
                  'TwiceAds UMP form dismissed: code=${formError.errorCode}, message=${formError.message}',
                );
              }
              if (!consentCompleter.isCompleted) consentCompleter.complete();
            });
          } catch (e) {
            debugPrint('TwiceAds UMP form show threw: $e');
            if (!consentCompleter.isCompleted) consentCompleter.complete();
          }
        },
        (FormError error) {
          debugPrint(
            'TwiceAds UMP update failed (offline or unconfigured): code=${error.errorCode}, message=${error.message}',
          );
          if (!consentCompleter.isCompleted) consentCompleter.complete();
        },
      );
    } catch (e) {
      debugPrint('TwiceAds UMP requestConsentInfoUpdate threw: $e');
      if (!consentCompleter.isCompleted) consentCompleter.complete();
    }

    // Never block initialization indefinitely on consent network requests.
    await consentCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        debugPrint('TwiceAds UMP consent flow timed out; proceeding safely');
      },
    );

    // Check if ads can be requested according to user consent or platform default.
    bool canRequest = true;
    try {
      canRequest = await ConsentInformation.instance.canRequestAds();
    } catch (_) {
      // Offline fallback: allow standard/non-personalized ad requests.
      canRequest = true;
    }

    if (!canRequest) {
      debugPrint('TwiceAds: Ads cannot be requested per UMP consent status.');
      return false;
    }

    return _initMobileAds();
  }

  static Future<bool> _initMobileAds() async {
    try {
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(testDeviceIds: TwiceAdConfig.testDeviceIds),
      );
      final status = await MobileAds.instance.initialize();
      for (final entry in status.adapterStatuses.entries) {
        debugPrint(
          'TwiceAds adapter: ${entry.key} => ${entry.value.state.name} (${entry.value.description})',
        );
      }
      return true;
    } catch (e) {
      debugPrint('TwiceAds MobileAds.initialize failed: $e');
      return false;
    }
  }

  /// Start loading the ad for [slot] in the background (no-op if it exists).
  static Future<void> prefetch(int slot) async {
    if (slot < 0 || slot >= TwiceAdConfig.maxAdSlots) return;
    await _obtain(slot);
  }

  /// Notifies the pool whether an ad is currently mounted in an AdWidget.
  static void markMounted(int slot, bool mounted) {
    final entry = _pool[slot];
    if (entry != null) {
      entry.isMounted = mounted;
    }
  }

  /// Returns a loaded ad for [slot] and increments ref count.
  /// If the pooled ad is currently mounted in another active widget, returns a fresh
  /// ad to prevent 'This AdWidget is already in the Widget tree' crashes.
  static Future<NativeAd?> acquire(int slot) async {
    final entry = await _obtain(slot);
    if (entry == null) return null;
    entry.refs++;
    return entry.ad;
  }

  static void release(int slot) {
    final entry = _pool[slot];
    if (entry == null) return;
    entry.refs = entry.refs > 0 ? entry.refs - 1 : 0;
    _evict();
  }

  static Future<_PoolEntry?> _obtain(int slot) {
    final cached = _pool[slot];
    if (cached != null && !cached.stale && !cached.isMounted) {
      return Future.value(cached);
    }
    if (cached != null && cached.stale && cached.refs == 0 && !cached.isMounted) {
      _pool.remove(slot);
      try {
        cached.ad.dispose();
      } catch (_) {}
    } else if (cached != null && !cached.isMounted) {
      return Future.value(cached);
    }

    final failed = _failedAt[slot];
    if (failed != null &&
        DateTime.now().difference(failed) < TwiceAdConfig.failureBackoff) {
      return Future.value(null);
    }

    return _pending[slot] ??= _load(slot).whenComplete(() {
      _pending.remove(slot);
    });
  }

  static Future<_PoolEntry?> _load(
    int slot, {
    String? overrideUnitId,
    bool isFallback = false,
  }) async {
    if (!await _ensureInit()) return null;

    final unitId = overrideUnitId ?? TwiceAdConfig.nativeUnitId;
    final done = Completer<_PoolEntry?>();

    final ad = NativeAd(
      adUnitId: unitId,
      request: const AdRequest(),
      nativeTemplateStyle: _instagramDarkStyle(),
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
          debugPrint('TwiceAds: Slot $slot loaded successfully ($unitId)');
          final entry = _PoolEntry(loaded as NativeAd);
          _pool[slot] = entry;
          _failedAt.remove(slot);
          if (!done.isCompleted) done.complete(entry);
        },
        onAdFailedToLoad: (failedAd, error) {
          final codeName = _adErrorCodeName(error.code);
          debugPrint(
            'TwiceAds: Slot $slot failed to load [code=${error.code} ($codeName), '
            'domain=${error.domain}, message=${error.message}]',
          );
          try {
            failedAd.dispose();
          } catch (_) {}

          // If testing in debug mode and video unit returned NO_FILL, fall back to
          // official standard Native Advanced test unit before giving up.
          if (!kReleaseMode &&
              !isFallback &&
              error.code == 3 &&
              unitId != TwiceAdConfig.testNativeUnitId) {
            debugPrint(
              'TwiceAds: Slot $slot trying fallback test unit ${TwiceAdConfig.testNativeUnitId}',
            );
            _load(
              slot,
              overrideUnitId: TwiceAdConfig.testNativeUnitId,
              isFallback: true,
            ).then((fallbackEntry) {
              if (!done.isCompleted) done.complete(fallbackEntry);
            });
            return;
          }

          _failedAt[slot] = DateTime.now();
          if (!done.isCompleted) done.complete(null);
        },
      ),
    );

    try {
      await ad.load();
    } catch (e) {
      debugPrint('TwiceAds: Slot $slot load threw: $e');
      try {
        ad.dispose();
      } catch (_) {}
      if (!done.isCompleted) done.complete(null);
    }

    return done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('TwiceAds: Slot $slot load timed out');
        _failedAt[slot] = DateTime.now();
        return null;
      },
    );
  }

  static void _evict() {
    if (_pool.length <= _maxPooled) return;
    final idle = _pool.entries
        .where((e) => e.value.refs == 0 && !e.value.isMounted)
        .toList()
      ..sort((a, b) => a.value.loadedAt.compareTo(b.value.loadedAt));
    for (final e in idle) {
      if (_pool.length <= _maxPooled) break;
      _pool.remove(e.key);
      try {
        e.value.ad.dispose();
      } catch (_) {}
    }
  }

  /// Black / white / blue styling that matches Twice's Instagram-style dark UI.
  static NativeTemplateStyle _instagramDarkStyle() {
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
