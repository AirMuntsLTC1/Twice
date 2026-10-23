import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_cache.dart';

/// Registry of verified accounts.
///
/// Verification lives in the protected `public.verified_profiles` table: every
/// signed-in user can READ it, nobody can write it from the app (no insert /
/// update / delete policy), so a user cannot give themselves the badge. The
/// ids are cached on the device, so the badge shows instantly on cold start
/// and offline, then the list is refreshed from Supabase.
class TwiceVerified {
  TwiceVerified._();

  static final ValueNotifier<Set<String>> ids = ValueNotifier<Set<String>>(
    <String>{},
  );

  static const String _cacheAccount = 'global';
  static const String _cacheType = 'verified_ids';
  static bool _refreshing = false;

  static bool isVerified(String? userId) =>
      userId != null && userId.isNotEmpty && ids.value.contains(userId);

  static void _set(Set<String> next) {
    final current = ids.value;
    if (current.length == next.length && current.containsAll(next)) return;
    ids.value = next;
  }

  /// Loads the last known list from the device (instant, offline-safe).
  static Future<void> restore() async {
    try {
      final saved = await LocalCache.instance.get(_cacheAccount, _cacheType);
      if (saved is List) {
        _set(saved.map((e) => e.toString()).where((e) => e.isNotEmpty).toSet());
      }
    } catch (_) {}
  }

  /// Fetches the current list from Supabase. Never throws.
  static Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final rows = await Supabase.instance.client
          .from('verified_profiles')
          .select('user_id')
          .timeout(const Duration(seconds: 12));
      final fresh = (rows as List)
          .map((row) => (row as Map)['user_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      _set(fresh);
      await LocalCache.instance.put(
        _cacheAccount,
        _cacheType,
        fresh.toList(),
      );
    } catch (error) {
      debugPrint('Twice verified list refresh deferred: $error');
    } finally {
      _refreshing = false;
    }
  }

  /// Restore from disk first, then refresh from the network.
  static Future<void> start() async {
    await restore();
    await refresh();
  }
}

/// Animated, glowing verified seal. Tap it to read what it means.
///
/// Collapses to nothing when [userId] is not verified, so it is safe to put
/// next to EVERY name; it appears automatically when the registry knows the
/// account is verified.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({
    super.key,
    required this.userId,
    this.size = 16,
    this.name,
    this.username,
    this.leadingGap = 4,
  });

  final String? userId;
  final double size;
  final String? name;
  final String? username;
  final double leadingGap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: TwiceVerified.ids,
      builder: (context, verified, _) {
        final id = userId;
        if (id == null || id.isEmpty || !verified.contains(id)) {
          return const SizedBox.shrink();
        }
        return Semantics(
          button: true,
          label: 'Verified account. Tap to learn more.',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showVerifiedAbout(
              context,
              name: name,
              username: username,
            ),
            child: Padding(
              padding: EdgeInsets.only(left: leadingGap, top: 2, bottom: 2),
              child: AnimatedVerifiedSeal(size: size),
            ),
          ),
        );
      },
    );
  }
}

/// Puts the badge right after a name widget (usually a [Text]).
class VerifiedName extends StatelessWidget {
  const VerifiedName({
    super.key,
    required this.userId,
    required this.child,
    this.size = 15,
    this.name,
    this.username,
  });

  final String? userId;
  final Widget child;
  final double size;
  final String? name;
  final String? username;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: TwiceVerified.ids,
      builder: (context, verified, _) {
        final id = userId;
        if (id == null || id.isEmpty || !verified.contains(id)) return child;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(child: child),
            VerifiedBadge(
              userId: id,
              size: size,
              name: name,
              username: username,
            ),
          ],
        );
      },
    );
  }
}

/// Inline badge for rich text (comment rows, captions).
InlineSpan verifiedSpan(
  String? userId, {
  double size = 14,
  String? name,
  String? username,
}) {
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: VerifiedBadge(
      userId: userId,
      size: size,
      name: name,
      username: username,
    ),
  );
}

Future<void> showVerifiedAbout(
  BuildContext context, {
  String? name,
  String? username,
}) {
  final who = (name ?? '').trim();
  final handle = (username ?? '').trim().replaceFirst(RegExp(r'^@'), '');
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: const Color(0xFF121212),
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) {
      Widget point(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(
                Icons.check_circle_rounded,
                size: 18,
                color: Color(0xFF0095F6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: Color(0xFFD9D9D9),
                  fontSize: 14.5,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      );

      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 10),
              const AnimatedVerifiedSeal(size: 84),
              const SizedBox(height: 22),
              const Text(
                'Verified account',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (who.isNotEmpty || handle.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  who.isNotEmpty && handle.isNotEmpty
                      ? '$who  ·  @$handle'
                      : (who.isNotEmpty ? who : '@$handle'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFA8A8A8), fontSize: 14),
                ),
              ],
              const SizedBox(height: 18),
              const Text(
                'Twice has confirmed that this account is authentic and '
                'belongs to the person it represents.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    point('The account is real and its identity was checked.'),
                    point('The name and username are confirmed by Twice.'),
                    point(
                      'Only Twice can add or remove this badge. It cannot be '
                      'bought or set by other users.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0095F6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: const Text(
                    'Got it',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// The seal itself: scalloped blue badge + white check, a soft pulsing glow
/// and a light sweep that glides across every few seconds.
class AnimatedVerifiedSeal extends StatefulWidget {
  const AnimatedVerifiedSeal({super.key, this.size = 16});

  final double size;

  @override
  State<AnimatedVerifiedSeal> createState() => _AnimatedVerifiedSealState();
}

class _AnimatedVerifiedSealState extends State<AnimatedVerifiedSeal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the system "remove animations" setting.
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 0.25;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _SealPainter(_controller),
      ),
    );
  }
}

class _SealPainter extends CustomPainter {
  _SealPainter(this.t) : super(repaint: t);

  final Animation<double> t;

  static Path _sealPath(Offset c, double r) {
    final path = Path();
    const steps = 96;
    for (var i = 0; i <= steps; i++) {
      final a = (i / steps) * math.pi * 2;
      final rad = r * (0.90 + 0.10 * math.cos(8 * a));
      final x = c.dx + rad * math.cos(a);
      final y = c.dy + rad * math.sin(a);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final seal = _sealPath(c, r);
    final pulse = 0.5 + 0.5 * math.sin(v * math.pi * 2);

    // Glow.
    canvas.drawPath(
      seal,
      Paint()
        ..color = const Color(0xFF29B6FF).withValues(alpha: 0.28 + 0.34 * pulse)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          r * (0.45 + 0.35 * pulse),
        ),
    );

    // Body.
    canvas.drawPath(
      seal,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF4FD1FF),
            Color(0xFF0095F6),
            Color(0xFF4C5BFF),
          ],
          stops: <double>[0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // Light sweep (first 40% of every cycle, then it rests).
    if (v < 0.4) {
      final s = v / 0.4;
      final x = -r * 0.6 + s * (size.width + r * 1.2);
      final band = r * 0.32;
      final skew = r * 0.7;
      canvas.save();
      canvas.clipPath(seal);
      canvas.drawPath(
        Path()
          ..moveTo(x - band + skew, 0)
          ..lineTo(x + band + skew, 0)
          ..lineTo(x + band - skew, size.height)
          ..lineTo(x - band - skew, size.height)
          ..close(),
        Paint()
          ..color = Colors.white.withValues(
            alpha: 0.55 * math.sin(s * math.pi),
          ),
      );
      canvas.restore();
    }

    // Check mark.
    final u = size.width / 24;
    final check = Path()
      ..moveTo(7.0 * u, 12.4 * u)
      ..lineTo(10.4 * u, 15.7 * u)
      ..lineTo(17.0 * u, 8.6 * u);
    canvas.drawPath(
      check,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.4, size.width * 0.115)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SealPainter oldDelegate) => false;
}
