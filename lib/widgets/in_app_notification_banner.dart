import 'dart:io';

import 'package:flutter/material.dart';

import '../data/notification_service.dart';

/// Host that paints the top slide-in banner above the whole app.
class InAppNotificationHost extends StatelessWidget {
  const InAppNotificationHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _BannerLayer(),
        ),
      ],
    );
  }
}

class _BannerLayer extends StatelessWidget {
  const _BannerLayer();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: NotificationService.instance,
      builder: (context, _) {
        final event = NotificationService.instance.current;
        return IgnorePointer(
          ignoring: event == null,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            reverseDuration: const Duration(milliseconds: 220),
            transitionBuilder: (child, animation) {
              final offset = Tween<Offset>(
                begin: const Offset(0, -1.1),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              ));
              return SlideTransition(
                position: offset,
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: event == null
                ? const SizedBox.shrink(key: ValueKey('empty'))
                : _BannerCard(
                    key: ValueKey(event.id),
                    event: event,
                  ),
          ),
        );
      },
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({super.key, required this.event});

  final TwiceNotificationEvent event;

  IconData get _icon {
    switch (event.type) {
      case 'message':
        return Icons.chat_bubble_rounded;
      case 'like':
        return Icons.favorite_rounded;
      case 'comment':
      case 'reply':
        return Icons.mode_comment_rounded;
      case 'follow':
      case 'follow_request':
      case 'follow_accept':
        return Icons.person_add_alt_1_rounded;
      case 'save':
        return Icons.bookmark_rounded;
      case 'story_reaction':
      case 'story_reply':
        return Icons.auto_awesome_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  Color get _accent {
    switch (event.type) {
      case 'like':
        return const Color(0xFFFF2D55);
      case 'message':
        return const Color(0xFF0095F6);
      case 'follow':
      case 'follow_request':
      case 'follow_accept':
        return const Color(0xFF7C5CFF);
      default:
        return const Color(0xFF3797F0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final avatar = (event.actorAvatar ?? '').trim();

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, top > 0 ? 4 : 10, 12, 0),
          child: Dismissible(
            key: ValueKey('dismiss-${event.id}'),
            direction: DismissDirection.up,
            onDismissed: (_) => NotificationService.instance.dismissCurrent(),
            child: GestureDetector(
              onTap: () => NotificationService.instance.handleTap(),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E).withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2C2C2E)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: _accent.withValues(alpha: 0.2),
                      backgroundImage: avatar.startsWith('http')
                          ? NetworkImage(avatar)
                          : (avatar.startsWith('/') || avatar.startsWith('file'))
                              ? FileImage(
                                  File(
                                    avatar.startsWith('file:')
                                        ? Uri.parse(avatar).toFilePath()
                                        : avatar,
                                  ),
                                )
                              : null,
                      child: avatar.startsWith('http') ||
                              avatar.startsWith('/') ||
                              avatar.startsWith('file')
                          ? null
                          : Icon(_icon, color: _accent, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            event.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            event.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFB0B0B5),
                              fontSize: 13,
                              height: 1.25,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(_icon, color: _accent, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
