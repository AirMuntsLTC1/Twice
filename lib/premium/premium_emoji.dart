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
            child: Text(
              emoji,
              style: TextStyle(
                fontSize: 32,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
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
