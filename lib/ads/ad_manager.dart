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
  bool get stale => DateTime.now().difference(loadedAt) > TwiceAdConfig.adTtl;
}

/// Loads, preloads and pools native ads, one per feed "slot".
///
/// Why a pool: Flutter disposes feed rows that scroll far away. If every row
/// owned its ad, scrolling back would re-request (and re-bill the user's data
/// for) the same ad. The pool keeps recently loaded ads alive and hands the
/// same NativeAd back when a row is rebuilt.
class TwiceAds {
  TwiceAds._();

  static const int _maxPooled = 6;

  static Future<bool>? _initFuture;
  static final Map<int, _PoolEntry> _pool = {};
  static final Map<int, Future<_PoolEntry?>> _pending = {};
  static final Map<int, DateTime> _failedAt = {};

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Call once at startup (fire and forget). Also warms slot 0 so the first ad
  /// is already loaded by the time the user scrolls to it.
  static Future<void> init() async {
    if (!await _ensureInit()) return;
    unawaited(prefetch(0));
  }

  static Future<bool> _ensureInit() {
    if (!supported) return Future.value(false);
    return _initFuture ??= () async {
      try {
        await MobileAds.instance.updateRequestConfiguration(
          RequestConfiguration(testDeviceIds: TwiceAdConfig.testDeviceIds),
        );
        await MobileAds.instance.initialize();
        return true;
      } catch (e) {
        debugPrint('TwiceAds init failed: $e');
        return false;
      }
    }();
  }

  /// Start loading the ad for [slot] in the background (no-op if it exists).
  static Future<void> prefetch(int slot) async {
    if (slot < 0 || slot >= TwiceAdConfig.maxAdSlots) return;
    await _obtain(slot);
  }

  /// Returns the loaded ad for [slot] (loading it if needed) and pins it so it
  /// is not evicted while a row is showing it. Returns null if no fill.
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
    if (cached != null && !cached.stale) return Future.value(cached);
    if (cached != null && cached.stale && cached.refs == 0) {
      _pool.remove(slot);
      cached.ad.dispose();
    } else if (cached != null) {
      // Stale but currently on screen: keep showing it.
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

  static Future<_PoolEntry?> _load(int slot) async {
    if (!await _ensureInit()) return null;

    final done = Completer<_PoolEntry?>();
    final ad = NativeAd(
      adUnitId: TwiceAdConfig.nativeUnitId,
      request: const AdRequest(),
      nativeTemplateStyle: _instagramDarkStyle(),
      nativeAdOptions: NativeAdOptions(
        // Muted autoplay: sound only if the user taps the unmute control.
        videoOptions: VideoOptions(
          startMuted: true,
          clickToExpandRequested: false,
          customControlsRequested: false,
        ),
        mediaAspectRatio: MediaAspectRatio.any,
      ),
      listener: NativeAdListener(
        onAdLoaded: (loaded) {
          final entry = _PoolEntry(loaded as NativeAd);
          _pool[slot] = entry;
          _failedAt.remove(slot);
          if (!done.isCompleted) done.complete(entry);
        },
        onAdFailedToLoad: (failedAd, error) {
          debugPrint('Native ad slot $slot failed: ${error.message}');
          failedAd.dispose();
          _failedAt[slot] = DateTime.now();
          if (!done.isCompleted) done.complete(null);
        },
      ),
    );

    try {
      await ad.load();
    } catch (e) {
      debugPrint('Native ad load threw: $e');
      ad.dispose();
      if (!done.isCompleted) done.complete(null);
    }

    return done.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _failedAt[slot] = DateTime.now();
        return null;
      },
    );
  }

  static void _evict() {
    if (_pool.length <= _maxPooled) return;
    final idle = _pool.entries.where((e) => e.value.refs == 0).toList()
      ..sort((a, b) => a.value.loadedAt.compareTo(b.value.loadedAt));
    for (final e in idle) {
      if (_pool.length <= _maxPooled) break;
      _pool.remove(e.key);
      e.value.ad.dispose();
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
