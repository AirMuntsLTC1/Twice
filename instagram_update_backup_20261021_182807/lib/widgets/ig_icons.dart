import 'package:flutter/material.dart';

class IgHeart extends StatelessWidget {
  const IgHeart({super.key, this.size = 26, this.filled = false, this.color});
  final double size;
  final bool filled;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? (filled ? const Color(0xFFFF3040) : Colors.white);
    return Icon(filled ? Icons.favorite : Icons.favorite_border, size: size, color: c);
  }
}

class IgComment extends StatelessWidget {
  const IgComment({super.key, this.size = 26, this.color = Colors.white});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => Icon(Icons.chat_bubble_outline, size: size, color: color);
}

class IgShare extends StatelessWidget {
  const IgShare({super.key, this.size = 26, this.color = Colors.white});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => Icon(Icons.send_outlined, size: size, color: color);
}

class IgSave extends StatelessWidget {
  const IgSave({super.key, this.size = 26, this.filled = false, this.color = Colors.white});
  final double size;
  final bool filled;
  final Color color;
  @override
  Widget build(BuildContext context) =>
      Icon(filled ? Icons.bookmark : Icons.bookmark_border, size: size, color: color);
}

class IgMessenger extends StatelessWidget {
  const IgMessenger({super.key, this.size = 26, this.color = Colors.white});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => Icon(Icons.near_me_outlined, size: size, color: color);
}

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
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
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
    if (vertical) return Column(mainAxisSize: MainAxisSize.min, children: kids);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 4),
      child: Row(children: kids),
    );
  }

  Widget _tap(VoidCallback onTap, Widget child) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(padding: const EdgeInsets.all(4), child: child),
      );

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}
