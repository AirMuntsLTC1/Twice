import 'package:flutter/material.dart';

/// Instagram-faithful outline / filled icons for feed + messages + videos.
/// Material Icons alone never match IG; these custom painters get close.
class IgHeart extends StatelessWidget {
  const IgHeart({
    super.key,
    this.size = 26,
    this.filled = false,
    this.color,
  });

  final double size;
  final bool filled;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? (filled ? const Color(0xFFFF3040) : Colors.white);
    return Icon(
      filled ? Icons.favorite : Icons.favorite_border,
      size: size,
      color: c,
    );
  }
}

class IgComment extends StatelessWidget {
  const IgComment({super.key, this.size = 26, this.color = Colors.white});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _BubblePainter(color: color, strokeWidth: size * 0.07),
      );
}

class IgShare extends StatelessWidget {
  const IgShare({super.key, this.size = 26, this.color = Colors.white});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _PaperPlanePainter(color: color, strokeWidth: size * 0.07),
      );
}

class IgSave extends StatelessWidget {
  const IgSave({
    super.key,
    this.size = 26,
    this.filled = false,
    this.color = Colors.white,
  });
  final double size;
  final bool filled;
  final Color color;

  @override
  Widget build(BuildContext context) => Icon(
        filled ? Icons.bookmark : Icons.bookmark_border,
        size: size,
        color: color,
      );
}

class IgMessenger extends StatelessWidget {
  const IgMessenger({super.key, this.size = 26, this.color = Colors.white});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _MessengerPainter(color: color, strokeWidth: size * 0.07),
      );
}

// ---------------------------------------------------------------------------
// Painters
// ---------------------------------------------------------------------------

class _BubblePainter extends CustomPainter {
  _BubblePainter({required this.color, required this.strokeWidth});
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    // Rounded speech bubble
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width * 0.08, size.height * 0.05, size.width * 0.84,
          size.height * 0.72),
      Radius.circular(size.width * 0.28),
    );
    path.addRRect(r);
    // Tail
    path.moveTo(size.width * 0.22, size.height * 0.72);
    path.quadraticBezierTo(
      size.width * 0.18,
      size.height * 0.88,
      size.width * 0.08,
      size.height * 0.95,
    );
    path.quadraticBezierTo(
      size.width * 0.28,
      size.height * 0.88,
      size.width * 0.32,
      size.height * 0.76,
    );
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant _BubblePainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}

class _PaperPlanePainter extends CustomPainter {
  _PaperPlanePainter({required this.color, required this.strokeWidth});
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(size.width * 0.08, size.height * 0.48)
      ..lineTo(size.width * 0.92, size.height * 0.12)
      ..lineTo(size.width * 0.48, size.height * 0.92)
      ..lineTo(size.width * 0.40, size.height * 0.55)
      ..close();
    // Fold line
    path.moveTo(size.width * 0.40, size.height * 0.55);
    path.lineTo(size.width * 0.92, size.height * 0.12);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant _PaperPlanePainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}

class _MessengerPainter extends CustomPainter {
  _MessengerPainter({required this.color, required this.strokeWidth});
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width * 0.08, size.height * 0.08, size.width * 0.84,
          size.height * 0.70),
      Radius.circular(size.width * 0.32),
    );
    path.addRRect(r);
    path.moveTo(size.width * 0.55, size.height * 0.75);
    path.quadraticBezierTo(
      size.width * 0.62,
      size.height * 0.92,
      size.width * 0.78,
      size.height * 0.95,
    );
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant _MessengerPainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}

/// Standard Instagram action row used under every post and on the video side.
class IgActionRow extends StatelessWidget {
  const IgActionRow({
    super.key,
    required this.liked,
    required this.saved,
    required this.onLike,
    required this.onComment,
    required this.onShare,
    required this.onSave,
    this.likeCount,
    this.vertical = false,
  });

  final bool liked;
  final bool saved;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onShare;
  final VoidCallback onSave;
  final int? likeCount;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final kids = <Widget>[
      _tap(onLike, IgHeart(filled: liked, size: vertical ? 28 : 26)),
      if (likeCount != null && vertical)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Text(
            _fmt(likeCount!),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        )
      else if (vertical)
        const SizedBox(height: 16),
      if (!vertical) const SizedBox(width: 14),
      _tap(onComment, const IgComment()),
      if (vertical) const SizedBox(height: 16),
      if (!vertical) const SizedBox(width: 14),
      _tap(onShare, const IgShare()),
      if (vertical) const SizedBox(height: 16),
      if (!vertical) const Spacer(),
      _tap(onSave, IgSave(filled: saved)),
    ];

    if (vertical) {
      return Column(mainAxisSize: MainAxisSize.min, children: kids);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 4),
      child: Row(children: kids),
    );
  }

  Widget _tap(VoidCallback onTap, Widget child) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: child,
        ),
      );

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}
