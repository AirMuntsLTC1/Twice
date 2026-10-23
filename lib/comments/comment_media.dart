import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../config/giphy_config.dart';

/// An attachment waiting to be sent with a comment.
/// [type] is one of: photo, gif, sticker, emoji.
class CommentAttachment {
  const CommentAttachment({required this.type, this.url, this.file});

  final String type;
  final String? url; // Giphy URL for gif / sticker / emoji
  final File? file; // local photo (uploaded when sending)

  bool get isPhoto => type == 'photo';
}

class GiphyItem {
  const GiphyItem({required this.previewUrl, required this.sendUrl});
  final String previewUrl;
  final String sendUrl;
}

enum GiphyKind { gifs, stickers, emoji }

class GiphyService {
  GiphyService._();
  static final GiphyService instance = GiphyService._();

  static const _host = 'api.giphy.com';

  Future<List<GiphyItem>> load(
    GiphyKind kind, {
    String query = '',
    int offset = 0,
    int limit = 30,
  }) async {
    final q = query.trim();
    final String path;
    switch (kind) {
      case GiphyKind.gifs:
        path = q.isEmpty ? '/v1/gifs/trending' : '/v1/gifs/search';
      case GiphyKind.stickers:
        path = q.isEmpty ? '/v1/stickers/trending' : '/v1/stickers/search';
      case GiphyKind.emoji:
        // Animated emoji; the emoji endpoint has no search, so filter by
        // searching stickers when the user types something.
        path = q.isEmpty ? '/v2/emoji' : '/v1/stickers/search';
    }
    final params = <String, String>{
      'api_key': kGiphyApiKey,
      'limit': '$limit',
      'offset': '$offset',
      'rating': 'pg-13',
      if (q.isNotEmpty) 'q': kind == GiphyKind.emoji ? '$q emoji' : q,
    };
    final uri = Uri.https(_host, path, params);
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('Giphy error ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final out = <GiphyItem>[];
    for (final raw in (body['data'] as List? ?? const [])) {
      final images = (raw as Map)['images'];
      if (images is! Map) continue;
      String? pick(List<String> keys) {
        for (final k in keys) {
          final v = images[k];
          if (v is Map && (v['url'] ?? '').toString().isNotEmpty) {
            return v['url'].toString();
          }
        }
        return null;
      }

      final preview = pick(['fixed_width_small', 'fixed_width', 'fixed_height']);
      final send = pick(['fixed_height', 'fixed_width', 'original']);
      if (preview == null || send == null) continue;
      out.add(GiphyItem(previewUrl: preview, sendUrl: send));
    }
    return out;
  }
}

/// Opens the Giphy picker (GIFs / Stickers / animated Emoji).
Future<CommentAttachment?> showGiphyPicker(
  BuildContext context, {
  GiphyKind initial = GiphyKind.gifs,
}) {
  return showModalBottomSheet<CommentAttachment>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _GiphySheet(initial: initial),
  );
}

class _GiphySheet extends StatefulWidget {
  const _GiphySheet({required this.initial});
  final GiphyKind initial;

  @override
  State<_GiphySheet> createState() => _GiphySheetState();
}

class _GiphySheetState extends State<_GiphySheet> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late GiphyKind _kind = widget.initial;
  List<GiphyItem> _items = [];
  bool _loading = true;
  bool _more = false;
  String? _error;
  Timer? _debounce;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) {
        _loadMore();
      }
    });
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final token = ++_token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await GiphyService.instance.load(
        _kind,
        query: _search.text,
      );
      if (!mounted || token != _token) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _loading = false;
        _error = 'Could not load. Check your connection.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_more || _loading || _items.isEmpty) return;
    _more = true;
    final token = _token;
    try {
      final next = await GiphyService.instance.load(
        _kind,
        query: _search.text,
        offset: _items.length,
      );
      if (!mounted || token != _token) return;
      setState(() => _items = [..._items, ...next]);
    } catch (_) {
    } finally {
      _more = false;
    }
  }

  void _pick(GiphyItem item) {
    final type = switch (_kind) {
      GiphyKind.gifs => 'gif',
      GiphyKind.stickers => 'sticker',
      GiphyKind.emoji => 'emoji',
    };
    Navigator.of(context).pop(CommentAttachment(type: type, url: item.sendUrl));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final cols = _kind == GiphyKind.gifs ? 2 : 4;
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        height: media.size.height * 0.62,
        decoration: const BoxDecoration(
          color: Color(0xFF121212),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF5A5A5A),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 450), _reload);
                },
                style: const TextStyle(fontSize: 15, color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search GIPHY',
                  hintStyle: const TextStyle(color: Color(0xFFA8A8A8)),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Color(0xFFA8A8A8),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF262626),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final k in GiphyKind.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(switch (k) {
                        GiphyKind.gifs => 'GIFs',
                        GiphyKind.stickers => 'Stickers',
                        GiphyKind.emoji => 'Emoji',
                      }),
                      selected: _kind == k,
                      onSelected: (_) {
                        if (_kind == k) return;
                        setState(() => _kind = k);
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          TextButton(
                            onPressed: _reload,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : _items.isEmpty
                  ? const Center(child: Text('Nothing found'))
                  : GridView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(8),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: 6,
                        mainAxisSpacing: 6,
                        childAspectRatio: _kind == GiphyKind.gifs ? 1.3 : 1,
                      ),
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        return GestureDetector(
                          onTap: () => _pick(item),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: ColoredBox(
                              color: const Color(0xFF1E1E1E),
                              child: Image.network(
                                item.previewUrl,
                                fit: _kind == GiphyKind.gifs
                                    ? BoxFit.cover
                                    : BoxFit.contain,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                'Powered by GIPHY',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFA8A8A8)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a comment's attachment (photo / GIF / sticker / animated emoji).
class CommentMediaView extends StatelessWidget {
  const CommentMediaView({super.key, required this.row, this.maxWidth = 220});

  /// A comments row. Optimistic rows may carry `_local_path` for photos.
  final Map<String, dynamic> row;
  final double maxWidth;

  static bool hasMedia(Map<String, dynamic> row) =>
      (row['media_url'] ?? '').toString().isNotEmpty ||
      (row['_local_path'] ?? '').toString().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final url = (row['media_url'] ?? '').toString();
    final local = (row['_local_path'] ?? '').toString();
    final type = (row['media_type'] ?? 'gif').toString();
    if (url.isEmpty && local.isEmpty) return const SizedBox.shrink();

    final transparent = type == 'sticker' || type == 'emoji';
    final width = type == 'emoji' ? 96.0 : maxWidth;
    final Widget image = local.isNotEmpty && url.isEmpty
        ? Image.file(File(local), width: width, fit: BoxFit.cover)
        : Image.network(
            url,
            width: width,
            fit: transparent ? BoxFit.contain : BoxFit.cover,
            gaplessPlayback: true,
            loadingBuilder: (c, child, p) => p == null
                ? child
                : SizedBox(
                    width: width,
                    height: 90,
                    child: const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
            errorBuilder: (_, _, _) => const SizedBox(
              width: 120,
              height: 60,
              child: Center(
                child: Icon(Icons.broken_image_outlined, color: Colors.grey),
              ),
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: transparent
          ? image
          : ClipRRect(borderRadius: BorderRadius.circular(14), child: image),
    );
  }
}

/// Text field + photo / emoji / GIF buttons + attachment preview.
/// The parent owns the controller and handles what happens on submit.
class CommentInputBar extends StatefulWidget {
  const CommentInputBar({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onSubmit,
    this.focusNode,
    this.leading,
    this.sending = false,
    this.sendColor = const Color(0xFF0095F6),
    this.fillColor,
    this.bordered = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final Widget? leading;
  final bool sending;
  final Color sendColor;
  final Color? fillColor;
  final bool bordered;

  /// Called with trimmed text and an optional attachment. Return normally once
  /// the comment has been handed off; the bar clears itself afterwards.
  final void Function(String text, CommentAttachment? attachment) onSubmit;

  @override
  State<CommentInputBar> createState() => _CommentInputBarState();
}

class _CommentInputBarState extends State<CommentInputBar> {
  CommentAttachment? _attachment;
  final ImagePicker _picker = ImagePicker();

  Future<void> _pickPhoto() async {
    try {
      // Photos only: the gallery picker below never offers video.
      final x = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (x == null || !mounted) return;
      setState(
        () => _attachment = CommentAttachment(type: 'photo', file: File(x.path)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open photos: $e')),
      );
    }
  }

  Future<void> _pickGiphy(GiphyKind kind) async {
    final picked = await showGiphyPicker(context, initial: kind);
    if (picked == null || !mounted) return;
    setState(() => _attachment = picked);
  }

  void _submit() {
    final text = widget.controller.text.trim();
    final attachment = _attachment;
    if (text.isEmpty && attachment == null) return;
    widget.onSubmit(text, attachment);
    if (mounted) setState(() => _attachment = null);
  }

  Widget _attachmentPreview() {
    final a = _attachment!;
    final Widget image = a.isPhoto
        ? Image.file(a.file!, height: 96, fit: BoxFit.cover)
        : Image.network(a.url!, height: 96, fit: BoxFit.contain);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Stack(
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(12), child: image),
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: () => setState(() => _attachment = null),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fill = widget.fillColor ?? const Color(0xFF262626);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_attachment != null) _attachmentPreview(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (widget.leading != null) ...[
              widget.leading!,
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(22),
                  border: widget.bordered
                      ? Border.all(color: const Color(0xFF363636))
                      : null,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        minLines: 1,
                        maxLines: 4,
                        textCapitalization: TextCapitalization.sentences,
                        style: const TextStyle(fontSize: 14.5),
                        decoration: InputDecoration(
                          hintText: widget.hintText,
                          hintStyle: const TextStyle(
                            color: Color(0xFFA8A8A8),
                            fontSize: 14.5,
                          ),
                          isDense: true,
                          filled: false,
                          contentPadding: const EdgeInsets.fromLTRB(
                            14,
                            11,
                            4,
                            11,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                    _MiniIcon(
                      icon: Icons.emoji_emotions_outlined,
                      tooltip: 'Animated emoji',
                      onTap: () => _pickGiphy(GiphyKind.emoji),
                    ),
                    _MiniIcon(
                      icon: Icons.gif_box_outlined,
                      tooltip: 'GIF',
                      onTap: () => _pickGiphy(GiphyKind.gifs),
                    ),
                    _MiniIcon(
                      icon: Icons.photo_outlined,
                      tooltip: 'Photo',
                      onTap: _pickPhoto,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, child) {
                final can =
                    (value.text.trim().isNotEmpty || _attachment != null) &&
                    !widget.sending;
                return IconButton(
                  onPressed: can ? _submit : null,
                  icon: Icon(
                    Icons.send_rounded,
                    color: can ? widget.sendColor : Colors.white24,
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _MiniIcon extends StatelessWidget {
  const _MiniIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 20,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
        child: Icon(icon, size: 22, color: const Color(0xFFA8A8A8)),
      ),
    );
  }
}
