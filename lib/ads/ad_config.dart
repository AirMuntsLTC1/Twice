/// Central AdMob configuration for Twice.
///
/// LIVE ADS ONLY. There are no Google test ad units anywhere in this app any
/// more: debug, profile and release builds all request your real native unit.
///
/// Policy reminder: never tap your own live ads. AdMob counts that as invalid
/// traffic and can suspend the account.
class TwiceAdConfig {
  TwiceAdConfig._();

  /// AdMob App ID (also declared in AndroidManifest.xml).
  static const String appId = 'ca-app-pub-2388362234538140~1307597758';

  /// Your real native ad unit (used for the feed AND the Videos tab).
  static const String nativeUnitId = 'ca-app-pub-2388362234538140/2313557661';

  /// One ad after every N organic posts in the Home feed.
  static const int feedInterval = 4;

  /// One ad after every N videos in the Videos tab.
  static const int videoInterval = 5;

  /// Hard cap on ad slots per placement.
  static const int maxAdSlots = 12;

  /// A loaded ad older than this is re-requested the next time it is needed.
  static const Duration adTtl = Duration(minutes: 50);

  /// After a failed request (no fill / network), wait before asking again.
  static const Duration failureBackoff = Duration(seconds: 60);

  /// Give up on a single ad request after this long.
  static const Duration loadTimeout = Duration(seconds: 12);

  /// Height reserved for the native ad (skeleton and ad share it, so nothing
  /// jumps when the ad appears).
  static const double adHeight = 380;

  /// The native view is only attached to the screen while the card is within
  /// this many viewport-heights of the visible area. Keeps the number of live
  /// platform views (the main cause of scroll jank) at one or two.
  static const double mountLookahead = 0.75;

  /// Most preloaded-but-unused ads kept in memory per placement.
  static const int maxPooledPerPlacement = 5;

  /// Optional: device hashes that should receive Google test creatives.
  /// Leave EMPTY for real ads on every device.
  static const List<String> testDeviceIds = <String>[];
}
