import 'ad_config.dart';

/// One row of the feed: either an organic item or a native ad slot.
/// Polymorphic on purpose: the feed is ONE sequential list, so ads scroll
/// inline exactly like posts (no pop-ups, no pre-rolls, no mid-rolls).
class FeedEntry<T> {
  const FeedEntry.item(T this.item) : adSlot = null;
  const FeedEntry.ad(int this.adSlot) : item = null;

  final T? item;
  final int? adSlot;

  bool get isAd => adSlot != null;
}

/// Interleaves an ad after every [interval] organic items.
///
/// * Ad slots are numbered 0,1,2... by position, so a slot keeps the same
///   identity (and the same preloaded ad) across rebuilds and pagination.
/// * No ad is ever added after the LAST item (an ad at the very end of the
///   feed looks like a dead end, not like a feed).
List<FeedEntry<T>> interleaveAds<T>(
  List<T> items, {
  int interval = TwiceAdConfig.feedInterval,
  int maxAds = TwiceAdConfig.maxAdSlots,
}) {
  final out = <FeedEntry<T>>[];
  var slot = 0;
  for (var i = 0; i < items.length; i++) {
    out.add(FeedEntry<T>.item(items[i]));
    final hasMore = i < items.length - 1;
    if (hasMore && (i + 1) % interval == 0 && slot < maxAds) {
      out.add(FeedEntry<T>.ad(slot++));
    }
  }
  return out;
}
