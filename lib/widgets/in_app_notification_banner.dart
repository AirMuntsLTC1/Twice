import 'package:flutter/material.dart';
import '../data/notification_service.dart';

/// App-wide foreground banner. It is intentionally separate from Android's
/// system tray notification, and only intercepts touches while visible.
class InAppNotificationHost extends StatelessWidget {
  const InAppNotificationHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          child,
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: _BannerLayer(),
            ),
          ),
        ],
      );
}

class _BannerLayer extends StatelessWidget {
  const _BannerLayer();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: NotificationService.instance,
        builder: (context, _) {
          final event = NotificationService.instance.current;
          return IgnorePointer(
            ignoring: event == null,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              transitionBuilder: (child, animation) => SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -1.15),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                )),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: event == null
                  ? const SizedBox.shrink(key: ValueKey('empty'))
                  : _BannerCard(key: ValueKey(event.id), event: event),
            ),
          );
        },
      );
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({super.key, required this.event});
  final TwiceNotificationEvent event;

  IconData get _icon {
    switch (event.type) {
      case 'message': return Icons.chat_bubble_rounded;
      case 'like': return Icons.favorite_rounded;
      case 'comment':
      case 'reply': return Icons.mode_comment_rounded;
      case 'follow':
      case 'follow_request':
      case 'follow_accept': return Icons.person_add_alt_1_rounded;
      case 'story_reaction': return Icons.auto_awesome_rounded;
      default: return Icons.notifications_rounded;
    }
  }

  Color get _accent {
    switch (event.type) {
      case 'message': return const Color(0xFF1877F2);
      case 'like': return const Color(0xFFE83E8C);
      case 'comment':
      case 'reply': return const Color(0xFF168B65);
      default: return const Color(0xFF6B63D9);
    }
  }

  @override
  Widget build(BuildContext context) {
    final actor = (event.actorName ?? '').trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 8),
      child: Material(
        color: const Color(0xFFF8FAFD),
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: .18),
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: NotificationService.instance.handleTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _accent,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_icon, color: Colors.white, size: 25),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF192333),
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text('now', style: TextStyle(
                          color: Color(0xFF718096), fontSize: 12,
                        )),
                      ]),
                      if (actor.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(actor, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Color(0xFF344054),
                            fontSize: 14, fontWeight: FontWeight.w600)),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        event.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF58677D),
                          fontSize: 14,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
