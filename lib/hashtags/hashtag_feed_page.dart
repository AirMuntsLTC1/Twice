import 'package:flutter/material.dart';

import '../data/social_repository.dart';

/// Minimal hashtag feed that reuses the existing grid/post rendering helpers
/// from main.dart. main.dart passes in a builder so we do not duplicate
/// PostCard / _MediaGridTile.
class HashtagFeedPage extends StatefulWidget {
  const HashtagFeedPage({
    super.key,
    required this.tag,
    required this.gridTileBuilder,
    required this.onOpenPost,
  });

  final String tag;
  final Widget Function(Map<String, dynamic> row, VoidCallback onTap) gridTileBuilder;
  final void Function(Map<String, dynamic> row) onOpenPost;

  @override
  State<HashtagFeedPage> createState() => _HashtagFeedPageState();
}

class _HashtagFeedPageState extends State<HashtagFeedPage> {
  List<Map<String, dynamic>>? _rows;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await SocialRepository.instance.postsByHashtag(widget.tag);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tag = widget.tag.startsWith('#') ? widget.tag : '#${widget.tag}';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(tag)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Could not load $tag',
                            style: const TextStyle(color: Colors.white70)),
                        const SizedBox(height: 8),
                        TextButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : (_rows == null || _rows!.isEmpty)
                  ? Center(
                      child: Text('No posts with $tag yet',
                          style: const TextStyle(color: Colors.white70)),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(2),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 2,
                        crossAxisSpacing: 2,
                      ),
                      itemCount: _rows!.length,
                      itemBuilder: (_, i) => widget.gridTileBuilder(
                        _rows![i],
                        () => widget.onOpenPost(_rows![i]),
                      ),
                    ),
    );
  }
}
