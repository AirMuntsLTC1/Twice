import 'package:flutter/material.dart';

class TwiceSkeleton extends StatefulWidget {
  const TwiceSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.borderRadius = 8,
    this.margin,
  });
  final double? width;
  final double height;
  final double borderRadius;
  final EdgeInsetsGeometry? margin;
  @override
  State<TwiceSkeleton> createState() => _TwiceSkeletonState();
}

class _TwiceSkeletonState extends State<TwiceSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
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
      builder: (_, __) {
        final t = _c.value;
        final base = const Color(0xFF262626);
        final highlight = const Color(0xFF3A3A3A);
        final color = Color.lerp(base, highlight, (t < 0.5 ? t : 1 - t) * 2)!;
        return Container(
          width: widget.width,
          height: widget.height,
          margin: widget.margin,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
        );
      },
    );
  }
}

class FeedSkeleton extends StatelessWidget {
  const FeedSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 8),
      children: [
        SizedBox(
          height: 98,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: 7,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, __) => const Column(
              children: [
                TwiceSkeleton(width: 64, height: 64, borderRadius: 32),
                SizedBox(height: 6),
                TwiceSkeleton(width: 48, height: 10, borderRadius: 4),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFF262626)),
        for (var i = 0; i < 3; i++) const _PostCardSkeleton(),
      ],
    );
  }
}

class _PostCardSkeleton extends StatelessWidget {
  const _PostCardSkeleton();
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                TwiceSkeleton(width: 36, height: 36, borderRadius: 18),
                SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TwiceSkeleton(width: 110, height: 12, borderRadius: 4),
                    SizedBox(height: 6),
                    TwiceSkeleton(width: 70, height: 10, borderRadius: 4),
                  ],
                ),
              ],
            ),
          ),
          TwiceSkeleton(width: w, height: w, borderRadius: 0),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                TwiceSkeleton(width: 26, height: 26, borderRadius: 6),
                SizedBox(width: 16),
                TwiceSkeleton(width: 26, height: 26, borderRadius: 6),
                SizedBox(width: 16),
                TwiceSkeleton(width: 26, height: 26, borderRadius: 6),
                Spacer(),
                TwiceSkeleton(width: 26, height: 26, borderRadius: 6),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: TwiceSkeleton(width: 80, height: 12, borderRadius: 4),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TwiceSkeleton(width: 220, height: 12, borderRadius: 4),
          ),
        ],
      ),
    );
  }
}

class InboxSkeleton extends StatelessWidget {
  const InboxSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 10,
      itemBuilder: (_, __) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            TwiceSkeleton(width: 56, height: 56, borderRadius: 28),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TwiceSkeleton(width: 140, height: 13, borderRadius: 4),
                  SizedBox(height: 8),
                  TwiceSkeleton(width: 200, height: 11, borderRadius: 4),
                ],
              ),
            ),
            TwiceSkeleton(width: 28, height: 10, borderRadius: 4),
          ],
        ),
      ),
    );
  }
}

class ChatSkeleton extends StatelessWidget {
  const ChatSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        Align(
          alignment: Alignment.centerLeft,
          child: TwiceSkeleton(width: 180, height: 40, borderRadius: 18),
        ),
        SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TwiceSkeleton(width: 140, height: 40, borderRadius: 18),
        ),
        SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TwiceSkeleton(width: 220, height: 56, borderRadius: 18),
        ),
        SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TwiceSkeleton(width: 100, height: 36, borderRadius: 18),
        ),
      ],
    );
  }
}
