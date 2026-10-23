import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

/// Gallery thumbnail that loads ONCE per asset.
///
/// The old code created `asset.thumbnailDataWithSize(...)` inside
/// `FutureBuilder(future: ...)` in build(), so every rebuild (scrolling the
/// picker, selecting an item, typing in the composer) restarted the load and
/// the tile flashed back to its placeholder. Here the future lives in State
/// and decoded bytes are kept in a small LRU, so a tile that scrolls back
/// into view paints instantly.
class AssetThumb extends StatefulWidget {
  const AssetThumb({
    super.key,
    required this.asset,
    this.size = 240,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  final AssetEntity asset;
  final int size;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;

  @override
  State<AssetThumb> createState() => _AssetThumbState();
}

class _ThumbCache {
  static const int _max = 160;
  static final LinkedHashMap<String, Uint8List> _bytes =
      LinkedHashMap<String, Uint8List>();

  static Uint8List? get(String key) {
    final value = _bytes.remove(key);
    if (value != null) _bytes[key] = value; // mark most recently used
    return value;
  }

  static void put(String key, Uint8List value) {
    _bytes.remove(key);
    _bytes[key] = value;
    while (_bytes.length > _max) {
      _bytes.remove(_bytes.keys.first);
    }
  }
}

class _AssetThumbState extends State<AssetThumb> {
  Uint8List? _data;
  bool _loading = false;

  String get _key => '${widget.asset.id}@${widget.size}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AssetThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id ||
        oldWidget.size != widget.size) {
      _data = null;
      _load();
    }
  }

  void _load() {
    final cached = _ThumbCache.get(_key);
    if (cached != null) {
      _data = cached;
      return;
    }
    if (_loading) return;
    _loading = true;
    final key = _key;
    widget.asset
        .thumbnailDataWithSize(ThumbnailSize(widget.size, widget.size))
        .then((bytes) {
          _loading = false;
          if (bytes == null || bytes.isEmpty) return;
          _ThumbCache.put(key, bytes);
          if (mounted && key == _key) setState(() => _data = bytes);
        })
        .catchError((Object _) {
          _loading = false;
        });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _data;
    if (bytes == null) {
      return widget.placeholder ??
          SizedBox(
            width: widget.width,
            height: widget.height,
            child: const ColoredBox(
              color: Color(0xFF262626),
              child: Center(child: Icon(Icons.image_outlined)),
            ),
          );
    }
    return Image.memory(
      bytes,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      cacheWidth: widget.size,
    );
  }
}
