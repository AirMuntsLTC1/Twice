import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

import '../comments/comment_media.dart';
import '../premium/premium_emoji.dart';

/// Result of the story editor. [editedFile] is non-null only when overlays
/// were added to a photo (they are flattened into a new PNG).
class StoryEditResult {
  const StoryEditResult({required this.caption, this.editedFile});
  final String caption;
  final File? editedFile;
}

/// Opens the full-screen story preview/editor for a picked asset.
Future<StoryEditResult?> openStoryEditor(
  BuildContext context,
  AssetEntity asset,
) {
  return Navigator.of(context).push<StoryEditResult>(
    MaterialPageRoute<StoryEditResult>(
      fullscreenDialog: true,
      builder: (_) => StoryEditorPage(asset: asset),
    ),
  );
}

enum _OverlayKind { text, emoji, sticker }

class _Overlay {
  _Overlay({
    required this.kind,
    this.text = '',
    this.url,
    this.color = Colors.white,
    this.background = false,
    required this.center,
  });

  final _OverlayKind kind;
  String text;
  final String? url;
  Color color;
  bool background;
  Offset center; // fraction (0..1) of the canvas
  double scale = 1;
  double rotation = 0;
}

const List<String> _kEmoji = [
  '😀', '😂', '🥹', '😍', '😘', '😎', '🤩', '🥳', '😭', '😡', '🥺', '😴',
  '🤯', '🤔', '🙄', '😇', '🤗', '😜', '🤪', '😏', '👍', '👎', '👏', '🙌',
  '🙏', '💪', '👀', '👋', '✌️', '🤞', '❤️', '🧡', '💛', '💚', '💙', '💜',
  '🖤', '🤍', '💔', '💕', '💖', '💯', '🔥', '✨', '⭐', '🌈', '☀️', '🌙',
  '⚡', '🎉', '🎊', '🎁', '🎂', '🍕', '🍔', '🍟', '🍩', '☕', '🍻', '🥂',
  '🐶', '🐱', '🦋', '🌸', '🌹', '🌴', '🏖️', '✈️', '🚗', '📸', '🎵', '🎶',
];

const List<Color> _kTextColors = [
  Colors.white,
  Colors.black,
  Color(0xFFFF3040),
  Color(0xFFFFC107),
  Color(0xFF4CAF50),
  Color(0xFF0095F6),
  Color(0xFFE040FB),
];

class StoryEditorPage extends StatefulWidget {
  const StoryEditorPage({super.key, required this.asset});
  final AssetEntity asset;

  @override
  State<StoryEditorPage> createState() => _StoryEditorPageState();
}

class _StoryEditorPageState extends State<StoryEditorPage> {
  final GlobalKey _canvasKey = GlobalKey();
  final TextEditingController _caption = TextEditingController();
  final List<_Overlay> _overlays = <_Overlay>[];

  File? _file;
  VideoPlayerController? _video;
  bool _loading = true;
  bool _exporting = false;
  String? _error;
  _Overlay? _active;
  bool _overTrash = false;
  bool _dragging = false;

  // Gesture baselines
  double _baseScale = 1;
  double _baseRotation = 0;

  bool get _isVideo => widget.asset.type == AssetType.video;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final file = await widget.asset.file;
      if (file == null) throw Exception('Could not read this media.');
      if (_isVideo) {
        final c = VideoPlayerController.file(file);
        await c.initialize();
        await c.setLooping(true);
        await c.setVolume(1);
        await c.play();
        _video = c;
      }
      if (!mounted) return;
      setState(() {
        _file = file;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _caption.dispose();
    _video?.dispose();
    super.dispose();
  }

  // ---- adding overlays ----------------------------------------------------

  void _add(_Overlay o) {
    setState(() {
      _overlays.add(o);
      _active = o;
    });
  }

  Future<void> _addText([_Overlay? existing]) async {
    final controller = TextEditingController(text: existing?.text ?? '');
    var color = existing?.color ?? Colors.white;
    var bg = existing?.background ?? false;
    final result = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Dialog.fullscreen(
          backgroundColor: Colors.transparent,
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.of(ctx).viewInsets.bottom + 12,
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Background',
                        onPressed: () => setLocal(() => bg = !bg),
                        icon: Icon(
                          Icons.text_fields_rounded,
                          color: bg ? const Color(0xFF0095F6) : Colors.white,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          'Done',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Center(
                      child: TextField(
                        controller: controller,
                        autofocus: true,
                        maxLines: null,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: color,
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          hintText: 'Type something',
                          hintStyle: TextStyle(color: Colors.white38),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final c in _kTextColors)
                          GestureDetector(
                            onTap: () => setLocal(() => color = c),
                            child: Container(
                              width: 30,
                              height: 30,
                              margin: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: color == c
                                      ? const Color(0xFF0095F6)
                                      : Colors.white54,
                                  width: color == c ? 3 : 1.5,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (result != true) return;
    if (existing != null) {
      setState(() {
        if (text.isEmpty) {
          _overlays.remove(existing);
        } else {
          existing.text = text;
          existing.color = color;
          existing.background = bg;
        }
      });
      return;
    }
    if (text.isEmpty) return;
    _add(
      _Overlay(
        kind: _OverlayKind.text,
        text: text,
        color: color,
        background: bg,
        center: const Offset(0.5, 0.45),
      ),
    );
  }

  Future<void> _openStickers() async {
    final choice = await showModalBottomSheet<_StickerChoice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _EmojiSheet(),
    );
    if (choice == null || !mounted) return;
    if (choice.emoji != null) {
      _add(
        _Overlay(
          kind: _OverlayKind.emoji,
          text: choice.emoji!,
          center: const Offset(0.5, 0.45),
        ),
      );
    } else if (choice.openGiphy) {
      final picked = await showGiphyPicker(context, initial: GiphyKind.stickers);
      if (picked?.url == null || !mounted) return;
      _add(
        _Overlay(
          kind: _OverlayKind.sticker,
          url: picked!.url,
          center: const Offset(0.5, 0.45),
        ),
      );
    }
  }

  // ---- gestures -----------------------------------------------------------

  void _onScaleStart(_Overlay o, ScaleStartDetails d) {
    _baseScale = o.scale;
    _baseRotation = o.rotation;
    setState(() {
      _active = o;
      _dragging = true;
    });
  }

  void _onScaleUpdate(_Overlay o, ScaleUpdateDetails d, Size canvas) {
    setState(() {
      o.center = Offset(
        (o.center.dx + d.focalPointDelta.dx / canvas.width).clamp(0.02, 0.98),
        (o.center.dy + d.focalPointDelta.dy / canvas.height).clamp(0.02, 0.98),
      );
      o.scale = (_baseScale * d.scale).clamp(0.4, 5.0);
      o.rotation = _baseRotation + d.rotation;
      _overTrash = o.center.dy > 0.9;
    });
  }

  void _onScaleEnd(_Overlay o) {
    setState(() {
      _dragging = false;
      if (_overTrash) {
        _overlays.remove(o);
        _active = null;
      }
      _overTrash = false;
    });
  }

  // ---- export -------------------------------------------------------------

  Future<void> _share() async {
    if (_exporting) return;
    FocusScope.of(context).unfocus();
    final caption = _caption.text;
    if (_isVideo || _overlays.isEmpty) {
      Navigator.of(context).pop(StoryEditResult(caption: caption));
      return;
    }
    setState(() {
      _exporting = true;
      _active = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      final boundary =
          _canvasKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw Exception('Could not render the story.');
      final Uint8List bytes = data.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final out = File(
        '${dir.path}/story_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await out.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      Navigator.of(context).pop(StoryEditResult(caption: caption, editedFile: out));
    } catch (e) {
      if (!mounted) return;
      setState(() => _exporting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not prepare story: $e')),
      );
    }
  }

  // ---- UI -----------------------------------------------------------------

  Widget _media() {
    if (_isVideo && _video != null) {
      return FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: _video!.value.size.width,
          height: _video!.value.size.height,
          child: VideoPlayer(_video!),
        ),
      );
    }
    return Image.file(
      _file!,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white54),
      ),
    );
  }

  Widget _overlayWidget(_Overlay o, Size canvas) {
    Widget content;
    switch (o.kind) {
      case _OverlayKind.emoji:
        content = Text(o.text, style: const TextStyle(fontSize: 64));
      case _OverlayKind.sticker:
        content = Image.network(
          o.url!,
          width: 160,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox(width: 160, height: 100),
        );
      case _OverlayKind.text:
        final fg = o.background
            ? (o.color == Colors.white ? Colors.black : Colors.white)
            : o.color;
        content = Container(
          constraints: BoxConstraints(maxWidth: canvas.width * 0.8),
          padding: o.background
              ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
              : EdgeInsets.zero,
          decoration: o.background
              ? BoxDecoration(
                  color: o.color,
                  borderRadius: BorderRadius.circular(10),
                )
              : null,
          child: Text(
            o.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: fg,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              shadows: o.background
                  ? null
                  : const [Shadow(blurRadius: 6, color: Colors.black54)],
            ),
          ),
        );
    }
    final selected = identical(o, _active) && !_exporting;
    return Positioned(
      left: o.center.dx * canvas.width,
      top: o.center.dy * canvas.height,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (o.kind == _OverlayKind.text) {
              _addText(o);
            } else {
              setState(() => _active = o);
            }
          },
          onScaleStart: (d) => _onScaleStart(o, d),
          onScaleUpdate: (d) => _onScaleUpdate(o, d, canvas),
          onScaleEnd: (_) => _onScaleEnd(o),
          child: Transform.rotate(
            angle: o.rotation,
            child: Transform.scale(
              scale: o.scale,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: selected
                    ? BoxDecoration(
                        border: Border.all(color: Colors.white54, width: 1),
                        borderRadius: BorderRadius.circular(8),
                      )
                    : null,
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolButton(IconData icon, String tip, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.black45,
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: tip,
          onPressed: onTap,
          icon: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Back'),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                        const Spacer(),
                        const Text(
                          'New story',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        const SizedBox(width: 48),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 9 / 16,
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final canvas = Size(box.maxWidth, box.maxHeight);
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  RepaintBoundary(
                                    key: _canvasKey,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      clipBehavior: Clip.hardEdge,
                                      children: [
                                        const ColoredBox(color: Colors.black),
                                        _media(),
                                        for (final o in _overlays)
                                          _overlayWidget(o, canvas),
                                      ],
                                    ),
                                  ),
                                  if (!_isVideo)
                                    Positioned(
                                      right: 8,
                                      top: 8,
                                      child: Column(
                                        children: [
                                          _toolButton(
                                            Icons.title_rounded,
                                            'Text',
                                            _addText,
                                          ),
                                          _toolButton(
                                            Icons.emoji_emotions_outlined,
                                            'Emoji & stickers',
                                            _openStickers,
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (_dragging)
                                    Positioned(
                                      bottom: 12,
                                      left: 0,
                                      right: 0,
                                      child: Center(
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                            milliseconds: 120,
                                          ),
                                          padding: EdgeInsets.all(
                                            _overTrash ? 16 : 12,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _overTrash
                                                ? Colors.red
                                                : Colors.black54,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.delete_outline_rounded,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_isVideo)
                                    const Positioned(
                                      left: 10,
                                      right: 10,
                                      bottom: 8,
                                      child: Text(
                                        'Videos are posted as-is. Text and stickers are available for photos.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: Colors.white70,
                                          shadows: [
                                            Shadow(
                                              blurRadius: 4,
                                              color: Colors.black,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _caption,
                            maxLength: 300,
                            maxLines: 1,
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: 'Add a caption…',
                              filled: true,
                              fillColor: const Color(0xFF262626),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.icon(
                          onPressed: _exporting ? null : _share,
                          icon: _exporting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_rounded, size: 18),
                          label: const Text('Share'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _StickerChoice {
  const _StickerChoice({this.emoji, this.openGiphy = false});
  final String? emoji;
  final bool openGiphy;
}

class _EmojiSheet extends StatelessWidget {
  const _EmojiSheet();

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Container(
      height: math.min(h * 0.55, 460),
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
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                const Text(
                  'Emoji',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.pop(
                    context,
                    const _StickerChoice(openGiphy: true),
                  ),
                  icon: const Icon(Icons.gif_box_outlined, size: 18),
                  label: const Text('GIPHY stickers'),
                ),
              ],
            ),
          ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        const TwicePremiumEmojiBadge(size: 18),
                        const SizedBox(width: 6),
                        const Text(
                          'Premium Emojis',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFFFF3040),
                                Color(0xFF4F5BD5),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: const Text(
                            'Unlock',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 6,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => PremiumEmojiTile(
                        emoji: ['🦄', '🌟', '🔥', '💎', '👑', '🎉', '🚀', '💖', '🪐', '⚡', '🍀', '🦋', '🎈', '🛸', '🎸', '🏆'][i % 16],
                      ),
                      childCount: 16,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                    child: Text(
                      'Standard',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.all(10),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 6,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => Navigator.pop(
                          context,
                          _StickerChoice(emoji: _kEmoji[i]),
                        ),
                        child: Center(
                          child: Text(
                            _kEmoji[i],
                            style: const TextStyle(fontSize: 30),
                          ),
                        ),
                      ),
                      childCount: _kEmoji.length,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}