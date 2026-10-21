import 'package:flutter/foundation.dart';

/// Central AdMob configuration for Twice.
///
/// Debug / profile builds ALWAYS use Google's official test ad unit so your own
/// account is never at risk of invalid-traffic flags. Release builds use your
/// real native ad unit. To force live ads in a debug build (not recommended):
///   flutter run --dart-define=TWICE_LIVE_ADS=true
class TwiceAdConfig {
  TwiceAdConfig._();

  /// AdMob App ID (also declared in AndroidManifest.xml).
  static const String appId = 'ca-app-pub-2388362234538140~1307597758';

  /// Your real native ad unit.
  static const String liveNativeUnitId =
      'ca-app-pub-2388362234538140/2313557661';

  /// Google's official "Native Advanced Video" test unit (Android).
  static const String testNativeVideoUnitId =
      'ca-app-pub-3940256099942544/1044960115';

  /// Google's official "Native Advanced" test unit for Native Templates (Android).
  static const String testNativeUnitId =
      'ca-app-pub-3940256099942544/2247696110';

  static const bool _forceLive = bool.fromEnvironment('TWICE_LIVE_ADS');

  static String get nativeUnitId =>
      (kReleaseMode || _forceLive) ? liveNativeUnitId : testNativeUnitId;

  /// One ad after every [feedInterval] organic posts (recommended 5 to 7).
  static const int feedInterval = 4;

  /// Hard cap so a very long feed never builds unlimited ad slots.
  static const int maxAdSlots = 12;

  /// An ad that has been loaded this long is considered stale and re-requested.
  static const Duration adTtl = Duration(minutes: 50);

  /// After a failed request, wait this long before asking again for that slot.
  static const Duration failureBackoff = Duration(seconds: 60);

  /// Height reserved for the native ad media block (skeleton and ad share it,
  /// so nothing jumps when the ad fades in).
  static const double adHeight = 380;

  /// Add your phone's test-device hash here (it is printed in logcat as
  /// "Use RequestConfiguration.Builder().setTestDeviceIds(...)") if you ever
  /// need to tap live ads on your own device safely.
  static const List<String> testDeviceIds = <String>[];
}