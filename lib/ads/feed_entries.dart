import 'ad_config.dart';

/// One row of a feed: either an organic item or a native ad slot.
/// The feed is ONE sequential list, so ads scroll inline exactly like posts
/// (no pop-ups, no pre-rolls, no mid-rolls).
class FeedEntry<T> {
  const FeedEntry.item(T this.item) : adSlot = null;
  const FeedEntry.ad(int this.adSlot) : item = null;

  final T? item;
  final int? adSlot;

  bool get isAd => adSlot != null;
}

/// Interleaves an ad after every [interval] organic items.
///
/// * Slots are numbered 0,1,2... by position, so a slot keeps the same
///   identity (and the same preloaded ad) across rebuilds and pagination.
/// * [skipSlots] lists slots known to have no fill: they are left out so the
///   user never lands on an empty page.
/// * No ad is ever added after the LAST item.
List<FeedEntry<T>> interleaveAds<T>(
  List<T> items, {
  int interval = TwiceAdConfig.feedInterval,
  int maxAds = TwiceAdConfig.maxAdSlots,
  Set<int> skipSlots = const <int>{},
}) {
  final out = <FeedEntry<T>>[];
  var slot = 0;
  for (var i = 0; i < items.length; i++) {
    out.add(FeedEntry<T>.item(items[i]));
    final hasMore = i < items.length - 1;
    if (hasMore && (i + 1) % interval == 0 && slot < maxAds) {
      final current = slot++;
      if (!skipSlots.contains(current)) out.add(FeedEntry<T>.ad(current));
    }
  }
  // A short feed (fewer items than [interval]) still gets one ad after its
  // last item, so a small or new account can show its first ad.
  if (TwiceAdConfig.showAdWhenFeedIsShort &&
      slot == 0 &&
      maxAds > 0 &&
      items.length >= 2 &&
      !skipSlots.contains(0)) {
    final at = items.length < interval ? items.length : interval;
    out.insert(at, FeedEntry<T>.ad(0));
  }
  return out;
}
