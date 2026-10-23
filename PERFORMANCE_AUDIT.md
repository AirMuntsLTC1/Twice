# PERFORMANCE_AUDIT.md - Twice

Generated: 20261023_111611

## Confirmed defects (source inspection)

1. Inbox Realtime channel churn - InboxController._connect() called _teardown()
   then created a channel on every auth-state/foreground event with no guard.
   Fixed with a _connecting flag and a stable channel topic.

2. Duplicate DM notification path - InboxController subscribed to both
   notifications (trigger-generated) and messages. Both could call
   presentFromRow, causing duplicate banners/profile fetches. The messages
   subscription now only refreshes unread counts.

3. Ad card layout geometry on every scroll frame - _isNear() called
   RenderAbstractViewport.getOffsetToReveal on every scroll notification for
   every mounted ad card. Replaced with VisibilityDetector fraction tracking;
   no layout queries on the scroll path.

4. Excessive feed cache extent - scrollCacheExtent was 1000 px, keeping
   offscreen video controllers alive. Reduced to 600 px.

5. Unhandled async exception risk in notification navigation -
   NotificationService.onTap was assigned _handleNotificationTap (async)
   directly. Wrapped with unawaited().

## Not changed (measurement needed)

- Comment / GIF rendering still uses Image.network with signed URLs. A future
  step could reuse TwiceNetworkImage for comment media.
- Chat bubble rebuilds on every notifyListeners(); acceptable for typical
  chat sizes.
- _PostMediaItem controller release uses a 4-second idle timer; a native
  controller pool would be the structural fix.

## Limitations

No runtime profiling possible in this environment. GitHub Actions must
validate build + analyze + test before APK is considered verified.
