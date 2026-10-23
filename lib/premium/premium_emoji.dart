import 'package:flutter/material.dart';
import 'premium_screen.dart';

/// Rotating red/purple/blue shader on a verified icon.
class TwicePremiumEmojiBadge extends StatefulWidget {
  const TwicePremiumEmojiBadge({super.key, required this.size});
  final double size;

  @override
  State<TwicePremiumEmojiBadge> createState() => _TwicePremiumEmojiBadgeState();
}

class _TwicePremiumEmojiBadgeState extends State<TwicePremiumEmojiBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _c,
      child: ShaderMask(
        shaderCallback: (Rect bounds) {
          return const LinearGradient(
            colors: [
              Color(0xFFFF3040),
              Color(0xFF962FBF),
              Color(0xFF4F5BD5),
              Color(0xFFFF3040),
            ],
            stops: [0.0, 0.4, 0.7, 1.0],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ).createShader(bounds);
        },
        child: Icon(
          Icons.verified_rounded,
          size: widget.size,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// A locked emoji. Tapping it opens the Premium billing screen.
class PremiumEmojiTile extends StatelessWidget {
  const PremiumEmojiTile({super.key, required this.emoji});
  final String emoji;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => const TwicePremiumScreen()),
        );
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AnimatedPremiumEmoji(emoji: emoji),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_rounded,
                size: 12,
                color: Color(0xFF0095F6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A premium badge to show next to premium users' names.
class TwicePremiumBadge extends StatefulWidget {
  const TwicePremiumBadge({super.key, this.size = 16});
  final double size;

  @override
  State<TwicePremiumBadge> createState() => _TwicePremiumBadgeState();
}

class _TwicePremiumBadgeState extends State<TwicePremiumBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween<double>(begin: 1.0, end: 1.15).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: Icon(
        Icons.workspace_premium_rounded,
        size: widget.size,
        color: const Color(0xFFFFD700), // Gold
      ),
    );
  }
}

/// An animated emoji that bounces/pulses continuously.
class AnimatedPremiumEmoji extends StatefulWidget {
  const AnimatedPremiumEmoji({super.key, required this.emoji});
  final String emoji;

  @override
  State<AnimatedPremiumEmoji> createState() => _AnimatedPremiumEmojiState();
}

class _AnimatedPremiumEmojiState extends State<AnimatedPremiumEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    // Stagger the animation start so they don't all bounce at the exact same time
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    Future.delayed(Duration(milliseconds: widget.emoji.hashCode % 800), () {
      if (mounted) _c.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        // Spin the emoji slightly, make it glow, and bounce it
        final scale = 0.9 + (_c.value * 0.25);
        final angle = (_c.value * 0.2) - 0.1; // Slight left/right tilt

        return Transform.rotate(
          angle: angle,
          child: Transform.scale(
            scale: scale,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.amber.withValues(alpha: 0.3 * _c.value),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: ShaderMask(
                shaderCallback: (Rect bounds) {
                  return LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: const [
                      Color(0xFFFFD700), // Gold
                      Color(0xFFFF3040), // Red
                      Color(0xFF4F5BD5), // Blue
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ).createShader(bounds);
                },
                child: Text(
                  widget.emoji,
                  style: const TextStyle(
                    fontSize: 32,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        blurRadius: 10,
                        color: Colors.black54,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
