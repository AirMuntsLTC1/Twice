import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'data/inbox_controller.dart';
import 'data/chat_controller.dart';
import 'data/social_repository.dart';
import 'widgets/skeleton.dart';

// Design tokens (match main.dart dark IG theme)
const _igBlack = Color(0xFF000000);
const _igSurface = Color(0xFF121212);
const _igElevated = Color(0xFF262626);
const _igBlue = Color(0xFF0095F6);
const _igMuted = Color(0xFFA8A8A8);
const _igBubbleMe = Color(0xFF3797F0);
const _igBubbleThem = Color(0xFF262626);

ImageProvider<Object>? _avatarProvider(String? source) {
  final v = (source ?? '').trim();
  if (v.isEmpty) return null;
  if (v.startsWith('file://')) {
    return FileImage(File.fromUri(Uri.parse(v)));
  }
  if (v.startsWith('/')) return FileImage(File(v));
  if (v.startsWith('http')) return NetworkImage(v);
  return null;
}

String _relativeTime(DateTime? dt) {
  if (dt == null) return '';
  final d = DateTime.now().difference(dt);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${dt.month}/${dt.day}';
}

// =============================================================================
// INBOX (Messages list) — Instagram style
// =============================================================================

class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    InboxController.instance.viewing = true;
    InboxController.instance.markAllRead();
    _load();
  }

  @override
  void dispose() {
    InboxController.instance.viewing = false;
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await SocialRepository.instance.conversationsDetailed();
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

  List<Map<String, dynamic>> get _filtered {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows.where((r) {
      final name = (r['other_name'] ?? '').toString().toLowerCase();
      final user = (r['other_username'] ?? '').toString().toLowerCase();
      final preview = (r['last_body'] ?? '').toString().toLowerCase();
      return name.contains(q) || user.contains(q) || preview.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _igBlack,
      appBar: AppBar(
        backgroundColor: _igBlack,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Messages',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 22,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, color: Colors.white),
            onPressed: () {
              // New message — open people picker (re-use existing start flow)
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Open a profile and tap Message to start a chat'),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Search',
                hintStyle: const TextStyle(color: _igMuted),
                prefixIcon: const Icon(Icons.search, color: _igMuted, size: 22),
                filled: true,
                fillColor: _igElevated,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const InboxSkeleton();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not load conversations\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _igMuted),
              ),
              const SizedBox(height: 16),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final list = _filtered;
    if (list.isEmpty) {
      return const Center(
        child: Text(
          'No messages yet.\nStart a conversation from a profile.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _igMuted, height: 1.5),
        ),
      );
    }
    return RefreshIndicator(
      color: _igBlue,
      backgroundColor: _igSurface,
      onRefresh: _load,
      child: ListView.builder(
        itemCount: list.length,
        itemBuilder: (_, i) => _ConversationTile(
          data: list[i],
          onOpen: () async {
            final r = list[i];
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ConversationPage(
                  conversationId: r['conversation_id'].toString(),
                  title: (r['other_name'] ?? r['other_username'] ?? 'Chat')
                      .toString(),
                  otherUserId: (r['other_user_id'] ?? '').toString(),
                  otherAvatar: (r['other_avatar'] ?? '').toString(),
                  otherUsername: (r['other_username'] ?? '').toString(),
                ),
              ),
            );
            if (mounted) _load();
          },
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.data, required this.onOpen});
  final Map<String, dynamic> data;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final name = (data['other_name'] ?? data['other_username'] ?? 'User')
        .toString();
    final username = (data['other_username'] ?? '')
        .toString()
        .trim()
        .replaceFirst(RegExp(r'^@'), '');
    final avatar = (data['other_avatar'] ?? '').toString();
    final preview = (data['last_body'] ?? '').toString();
    final mediaType = (data['last_media_type'] ?? '').toString();
    final unread = data['unread'] == true;
    final lastAt = data['last_at'] is DateTime
        ? data['last_at'] as DateTime
        : DateTime.tryParse('${data['last_at'] ?? ''}');

    String subtitle;
    if (mediaType == 'image') {
      subtitle = '📷 Photo';
    } else if (mediaType == 'video') {
      subtitle = '🎬 Video';
    } else if (preview.isNotEmpty) {
      subtitle = preview;
    } else {
      subtitle = 'Tap to open';
    }

    final prov = _avatarProvider(avatar);

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: _igElevated,
              backgroundImage: prov,
              onBackgroundImageError: prov == null
                  ? null
                  : (exception, stackTrace) {},
              child: prov == null
                  ? Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (username.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      '@$username',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _igMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: unread ? Colors.white : _igMuted,
                      fontSize: 13.5,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _relativeTime(lastAt),
                  style: TextStyle(
                    color: unread ? _igBlue : _igMuted,
                    fontSize: 12,
                    fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (unread) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: _igBlue,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// CONVERSATION THREAD — Instagram style bubbles + media
// =============================================================================

// =============================================================================
// CONVERSATION THREAD — Instagram style bubbles + media
// =============================================================================


// =============================================================================
// CONVERSATION (Messenger-style chat room)
// =============================================================================

class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.conversationId,
    required this.title,
    this.otherUserId = '',
    this.otherAvatar = '',
    this.otherUsername = '',
  });

  final String conversationId;
  final String title;
  final String otherUserId;
  final String otherAvatar;
  final String otherUsername;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  late final ChatController _chat;
  bool _stickToBottom = true;
  int _lastCount = 0;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chat = ChatController(widget.conversationId);
    _chat.addListener(_onChatChanged);
    _scroll.addListener(_onScroll);
    InboxController.instance.markConversationRead(widget.conversationId);
    unawaited(
      _chat.start(
        peerUserId:
            widget.otherUserId.isEmpty ? null : widget.otherUserId,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_chat.load(initial: false));
      InboxController.instance.markConversationRead(widget.conversationId);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // With reverse:true, pixels near 0 means user is at the newest messages.
    _stickToBottom = _scroll.position.pixels < 80;
  }

  void _onChatChanged() {
    if (!mounted) return;
    final count = _chat.messages.length;
    final grew = count > _lastCount;
    setState(() {});
    if (grew && _stickToBottom) {
      _scrollToNewest();
    }
    _lastCount = count;
  }

  void _scrollToNewest({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      // reverse:true → newest at offset 0
      if (jump) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _sendText() async {
    final body = _text.text.trim();
    if (body.isEmpty || _chat.sending) return;
    _text.clear();
    _stickToBottom = true;
    unawaited(HapticFeedback.lightImpact());
    unawaited(SystemSound.play(SystemSoundType.click).catchError((_) {}));
    try {
      await _chat.sendText(body);
      _scrollToNewest();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send: $e')),
      );
    }
  }

  Future<void> _openGifPicker() async {
    if (_chat.sending) return;
    final gif = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _igSurface,
      builder: (_) => const _TwiceGifPicker(),
    );
    if (gif == null || !mounted) return;
    try {
      final file = await _TwiceGifCache.instance.downloadGif(gif);
      _stickToBottom = true;
      unawaited(SystemSound.play(SystemSoundType.click).catchError((_) {}));
      await _chat.sendMediaFile(file: file, mediaType: 'image');
      _scrollToNewest();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send GIF: $e')),
        );
      }
    }
  }

  Future<void> _pickAndSendMedia({required bool video}) async {
    final permitted = await PhotoManager.requestPermissionExtend();
    if (!permitted.isAuth && !permitted.hasAccess) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo library permission required')),
        );
      }
      return;
    }

    final paths = await PhotoManager.getAssetPathList(
      type: video ? RequestType.video : RequestType.image,
      onlyAll: true,
    );
    if (paths.isEmpty) return;

    final assets = await paths.first.getAssetListPaged(page: 0, size: 120);
    if (!mounted || assets.isEmpty) return;

    final selected = <AssetEntity>[];
    final chosen = await showModalBottomSheet<List<AssetEntity>>(
      context: context,
      backgroundColor: _igSurface,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.65,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        video
                            ? 'Choose a video'
                            : 'Choose photos (${selected.length}/10)',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.pop(sheetContext, List.of(selected)),
                      child: const Text('Send'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: assets.length,
                  itemBuilder: (_, index) {
                    final item = assets[index];
                    final isSelected = selected.contains(item);
                    return FutureBuilder<Uint8List?>(
                      future: item.thumbnailDataWithSize(
                        const ThumbnailSize(240, 240),
                      ),
                      builder: (context, snapshot) {
                        return InkWell(
                          onTap: () {
                            if (video) {
                              Navigator.pop(sheetContext, [item]);
                              return;
                            }
                            setSheetState(() {
                              if (isSelected) {
                                selected.remove(item);
                              } else if (selected.length < 10) {
                                selected.add(item);
                              }
                            });
                          },
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (snapshot.data != null)
                                Image.memory(
                                  snapshot.data!,
                                  fit: BoxFit.cover,
                                )
                              else
                                const ColoredBox(color: Color(0xFF1A1A1A)),
                              if (isSelected)
                                Container(
                                  color: Colors.black38,
                                  alignment: Alignment.center,
                                  child: const Icon(
                                    Icons.check_circle,
                                    color: _igBlue,
                                  ),
                                ),
                              if (item.type == AssetType.video)
                                const Positioned(
                                  right: 6,
                                  bottom: 6,
                                  child: Icon(
                                    Icons.play_circle_fill,
                                    color: Colors.white,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (chosen == null || chosen.isEmpty || !mounted) return;
    _stickToBottom = true;
    unawaited(SystemSound.play(SystemSoundType.click).catchError((_) {}));

    try {
      if (video) {
        final file = await chosen.first.file;
        if (file == null) throw StateError('Could not open video file');
        await _chat.sendMediaFile(file: file, mediaType: 'video');
      } else if (chosen.length == 1) {
        final file = await chosen.first.file;
        if (file == null) throw StateError('Could not open photo');
        await _chat.sendMediaFile(file: file, mediaType: 'image');
      } else {
        final files = <File>[];
        for (final a in chosen) {
          final f = await a.file;
          if (f != null) files.add(f);
        }
        if (files.isEmpty) throw StateError('Could not open photos');
        await _chat.sendMediaAlbum(files);
      }
      _scrollToNewest();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send media: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chat.removeListener(_onChatChanged);
    _chat.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _chat.otherOnline
        ? 'Active now'
        : (_chat.otherLastSeen != null
            ? 'Active ${_relativeTime(_chat.otherLastSeen)}'
            : (widget.otherUsername.isNotEmpty
                ? '@${widget.otherUsername}'
                : ''));

    return Scaffold(
      backgroundColor: _igBlack,
      appBar: AppBar(
        backgroundColor: _igBlack,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: _igElevated,
              backgroundImage: _avatarProvider(widget.otherAvatar),
              child: _avatarProvider(widget.otherAvatar) == null
                  ? const Icon(Icons.person, size: 18, color: _igMuted)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: _chat.otherOnline
                            ? const Color(0xFF31A24C)
                            : _igMuted,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            tooltip: 'Refresh',
            onPressed: () => _chat.load(initial: false),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageList()),
          _composer(),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_chat.loading && _chat.messages.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: _igBlue, strokeWidth: 2),
      );
    }
    if (_chat.error != null && _chat.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not load messages\n${_chat.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _igMuted),
              ),
              TextButton(
                onPressed: () => _chat.load(initial: true),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final msgs = _chat.messages;
    if (msgs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: _igElevated,
              backgroundImage: _avatarProvider(widget.otherAvatar),
              child: _avatarProvider(widget.otherAvatar) == null
                  ? const Icon(Icons.person, size: 40, color: _igMuted)
                  : null,
            ),
            const SizedBox(height: 12),
            Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 6),
            const Text('Say hello 👋', style: TextStyle(color: _igMuted)),
          ],
        ),
      );
    }

    // reverse:true keeps newest messages pinned to the bottom without jumping
    // the list to the top when new rows are appended.
    return ListView.builder(
      key: PageStorageKey<String>('twice-chat-${widget.conversationId}'),
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      itemCount: msgs.length,
      itemBuilder: (_, i) {
        // i=0 is newest
        final index = msgs.length - 1 - i;
        final m = msgs[index];
        final prev = index > 0 ? msgs[index - 1] : null;
        final showAvatar = !m.isMine &&
            (prev == null || prev.senderId != m.senderId);
        return _ChatBubble(
          key: ValueKey<String>('bubble-${m.clientId}'),
          message: m,
          showAvatar: showAvatar,
          fallbackAvatar: widget.otherAvatar,
          onRetry: m.status == ChatSendStatus.failed
              ? () => unawaited(_chat.retry(m))
              : null,
        );
      },
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 10),
        decoration: const BoxDecoration(
          color: _igBlack,
          border: Border(top: BorderSide(color: _igElevated, width: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.camera_alt_outlined, color: _igMuted),
              onPressed:
                  _chat.sending ? null : () => _pickAndSendMedia(video: false),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: _igSurface,
                  border: Border.all(color: const Color(0xFF303030), width: 0.7),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15),
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendText(),
                        decoration: const InputDecoration(
                          hintText: 'Message...',
                          hintStyle: TextStyle(color: _igMuted),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.image_outlined,
                          color: _igMuted, size: 22),
                      onPressed: _chat.sending
                          ? null
                          : () => _pickAndSendMedia(video: false),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: 'Video',
                      icon: const Icon(Icons.videocam_outlined,
                          color: _igMuted, size: 22),
                      onPressed: _chat.sending
                          ? null
                          : () => _pickAndSendMedia(video: true),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: 'GIF',
                      icon: const Icon(Icons.gif_box_outlined,
                          color: _igMuted, size: 24),
                      onPressed: _chat.sending ? null : _openGifPicker,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: _chat.sending
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _igBlue,
                      ),
                    )
                  : const Icon(Icons.send_rounded, color: _igBlue),
              onPressed: _chat.sending ? null : _sendText,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Messenger-style bubble with send animation + status
// =============================================================================

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    super.key,
    required this.message,
    required this.showAvatar,
    this.fallbackAvatar = '',
    this.onRetry,
  });

  final ChatMessage message;
  final bool showAvatar;
  final String fallbackAvatar;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final own = message.isMine;
    final body = message.body;
    final mediaUrl = (message.resolvedMediaUrl ??
            (message.localFilePath != null
                ? 'file://${message.localFilePath}'
                : message.mediaUrl) ??
            '')
        .toString();
    final mediaType = (message.mediaType ?? '').toString();
    final createdAt = message.createdAt.toLocal();
    final timeLabel =
        '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
    final isRead = own && message.readAt != null;
    final hasMedia = mediaUrl.isNotEmpty &&
        (mediaUrl.startsWith('http') || mediaUrl.startsWith('file'));
    final attachments = message.resolvedAttachments.where((a) {
      final url = (a['resolved_media_url'] ?? a['local_file_path'] ?? '')
          .toString();
      return url.startsWith('http') ||
          url.startsWith('file') ||
          url.startsWith('/');
    }).toList();
    final hasAlbum = attachments.length > 1;

    final avatarUrl =
        (message.senderProfile?['avatar_url'] ?? fallbackAvatar).toString();
    final prov = _avatarProvider(avatarUrl);

    final statusIcon = !own
        ? null
        : message.status == ChatSendStatus.sending
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.4,
                  color: Colors.white70,
                ),
              )
            : message.status == ChatSendStatus.failed
                ? GestureDetector(
                    onTap: onRetry,
                    child: const Icon(Icons.error_outline,
                        size: 14, color: Colors.redAccent),
                  )
                : Icon(
                    isRead ? Icons.done_all : Icons.done,
                    size: 14,
                    color: isRead ? const Color(0xFF34B7F1) : Colors.white70,
                  );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(
            own ? 16 * (1 - value) : -10 * (1 - value),
            10 * (1 - value),
          ),
          child: child,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          top: showAvatar ? 10 : 2,
          bottom: 2,
          left: own ? 48 : 0,
          right: own ? 0 : 48,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment:
              own ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (!own) ...[
              if (showAvatar)
                CircleAvatar(
                  radius: 14,
                  backgroundColor: _igElevated,
                  backgroundImage: prov,
                  child: prov == null
                      ? const Icon(Icons.person, size: 14, color: _igMuted)
                      : null,
                )
              else
                const SizedBox(width: 28),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Column(
                crossAxisAlignment:
                    own ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: hasMedia || hasAlbum
                        ? const EdgeInsets.all(4)
                        : const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: own ? _igBubbleMe : _igBubbleThem,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(own ? 18 : 4),
                        bottomRight: Radius.circular(own ? 4 : 18),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hasAlbum)
                          _AlbumGrid(attachments: attachments)
                        else if (hasMedia)
                          _MediaThumb(
                            url: mediaUrl,
                            isVideo: mediaType == 'video',
                          ),
                        if (body.trim().isNotEmpty) ...[
                          if (hasMedia || hasAlbum) const SizedBox(height: 6),
                          Padding(
                            padding: (hasMedia || hasAlbum)
                                ? const EdgeInsets.fromLTRB(8, 0, 8, 6)
                                : EdgeInsets.zero,
                            child: Text(
                              body,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        timeLabel,
                        style: const TextStyle(color: _igMuted, fontSize: 10),
                      ),
                      if (statusIcon != null) ...[
                        const SizedBox(width: 4),
                        statusIcon,
                      ],
                    ],
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

class _MediaThumb extends StatelessWidget {
  const _MediaThumb({required this.url, required this.isVideo});
  final String url;
  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    final provider = _avatarProvider(url);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        children: [
          SizedBox(
            width: 220,
            height: 280,
            child: provider != null
                ? Image(
                    image: provider,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: _igElevated,
                      alignment: Alignment.center,
                      child: const Icon(Icons.broken_image, color: _igMuted),
                    ),
                  )
                : Container(color: _igElevated),
          ),
          if (isVideo)
            const Positioned.fill(
              child: Center(
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white, size: 48),
              ),
            ),
        ],
      ),
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.attachments});
  final List<Map<String, dynamic>> attachments;

  @override
  Widget build(BuildContext context) {
    final count = attachments.length.clamp(1, 4);
    return SizedBox(
      width: 220,
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: count == 1 ? 1 : 2,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
        ),
        itemCount: count,
        itemBuilder: (_, i) {
          final a = attachments[i];
          var url = (a['resolved_media_url'] ?? '').toString();
          if (url.isEmpty) {
            final local = (a['local_file_path'] ?? '').toString();
            if (local.isNotEmpty) {
              url = local.startsWith('file:') ? local : 'file://$local';
            }
          }
          final prov = _avatarProvider(url);
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: prov != null
                ? Image(image: prov, fit: BoxFit.cover)
                : Container(color: _igElevated),
          );
        },
      ),
    );
  }
}

const _giphyApiKey = 'RTUwFs8WOiFqRq0K9UBkWS0OlUy3tVza';

class _TwiceGifCache {
  _TwiceGifCache._();
  static final instance = _TwiceGifCache._();

  Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'twice_gif_cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _name(String value, String ext) {
    final encoded = base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    return '${encoded.substring(0, encoded.length > 120 ? 120 : encoded.length)}.$ext';
  }

  Future<File?> cachedPreview(String url) async {
    try {
      final f = File(p.join((await _dir()).path, _name(url, 'preview.gif')));
      return await f.exists() && await f.length() > 0 ? f : null;
    } catch (_) { return null; }
  }

  Future<void> cachePreview(String url) async {
    try {
      if (await cachedPreview(url) != null) return;
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return;
      final f = File(p.join((await _dir()).path, _name(url, 'preview.gif')));
      await f.writeAsBytes(response.bodyBytes, flush: true);
    } catch (_) {}
  }

  Future<File> downloadGif(Map<String, dynamic> gif) async {
    final images = gif['images'] as Map? ?? const {};
    final original = images['original'] as Map? ?? const {};
    final url = (original['url'] ?? '').toString();
    if (url.isEmpty) throw StateError('GIF URL is missing.');
    final target = File(p.join((await _dir()).path, _name(url, 'gif')));
    if (await target.exists() && await target.length() > 0) return target;
    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw HttpException('GIPHY returned ${response.statusCode}');
      }
      await target.writeAsBytes(response.bodyBytes, flush: true);
      return target;
    } catch (_) {
      // If offline, send the already-cached animated preview for this GIF.
      final previewUrl = (images['fixed_width'] as Map?)?['url']?.toString()
          ?? (images['preview_gif'] as Map?)?['url']?.toString();
      if (previewUrl != null) {
        final cached = await cachedPreview(previewUrl);
        if (cached != null) return cached;
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> cachedResults() async {
    try {
      final f = File(p.join((await _dir()).path, 'results.json'));
      if (!await f.exists()) return [];
      final decoded = jsonDecode(await f.readAsString());
      return decoded is List
          ? decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : [];
    } catch (_) { return []; }
  }

  Future<void> saveResults(List<Map<String, dynamic>> rows) async {
    try {
      final f = File(p.join((await _dir()).path, 'results.json'));
      await f.writeAsString(jsonEncode(rows), flush: true);
    } catch (_) {}
  }
}

class _TwiceGifPicker extends StatefulWidget {
  const _TwiceGifPicker();
  @override
  State<_TwiceGifPicker> createState() => _TwiceGifPickerState();
}

class _TwiceGifPickerState extends State<_TwiceGifPicker> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _gifs = [];
  bool _loading = true;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadOfflineFirst();
    _search.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.removeListener(_onSearchChanged);
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _fetch(_search.text.trim());
    });
  }

  Future<void> _loadOfflineFirst() async {
    final cached = await _TwiceGifCache.instance.cachedResults();
    if (mounted && cached.isNotEmpty) {
      setState(() { _gifs = cached; _loading = false; });
    }
    await _fetch('');
  }

  Future<void> _fetch(String query) async {
    if (!mounted) return;
    setState(() { _loading = _gifs.isEmpty; _error = null; });
    try {
      final endpoint = query.isEmpty ? 'trending' : 'search';
      final uri = Uri.https('api.giphy.com', '/v1/gifs/$endpoint', {
        'api_key': _giphyApiKey,
        'limit': '40',
        'rating': 'pg-13',
        if (query.isNotEmpty) 'q': query,
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) throw HttpException('GIPHY ${response.statusCode}');
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final data = (decoded['data'] as List? ?? const [])
          .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      if (!mounted) return;
      setState(() { _gifs = data; _loading = false; });
      if (query.isEmpty) await _TwiceGifCache.instance.saveResults(data);
      for (final gif in data.take(18)) {
        final images = gif['images'] as Map? ?? const {};
        final preview = (images['fixed_width'] as Map?)?['url']?.toString()
            ?? (images['preview_gif'] as Map?)?['url']?.toString();
        if (preview != null && preview.isNotEmpty) {
          unawaited(_TwiceGifCache.instance.cachePreview(preview));
        }
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'Offline: showing cached GIFs'; });
    }
  }

  String? _previewUrl(Map<String, dynamic> gif) {
    final images = gif['images'] as Map? ?? const {};
    return (images['fixed_width'] as Map?)?['url']?.toString()
        ?? (images['preview_gif'] as Map?)?['url']?.toString();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Row(children: [
                const Text('GIFs', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, color: Colors.white)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: TextField(
                controller: _search,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search for GIFs',
                  hintStyle: const TextStyle(color: _igMuted),
                  prefixIcon: const Icon(Icons.search, color: _igMuted),
                  filled: true, fillColor: const Color(0xFF242424),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: const TextStyle(color: _igMuted, fontSize: 12))),
            Expanded(
              child: _loading && _gifs.isEmpty
                  ? const Center(child: CircularProgressIndicator(color: _igBlue))
                  : _gifs.isEmpty
                      ? const Center(child: Text('No GIFs found', style: TextStyle(color: _igMuted)))
                      : GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 1.15),
                          itemCount: _gifs.length,
                          itemBuilder: (_, index) {
                            final gif = _gifs[index];
                            final preview = _previewUrl(gif);
                            return GestureDetector(
                              onTap: () => Navigator.pop(context, gif),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: preview == null
                                    ? Container(color: _igElevated)
                                    : FutureBuilder<File?>(
                                        future: _TwiceGifCache.instance.cachedPreview(preview),
                                        builder: (_, snap) {
                                          if (snap.data != null) return Image.file(snap.data!, fit: BoxFit.cover, gaplessPlayback: true);
                                          return Image.network(preview, fit: BoxFit.cover, gaplessPlayback: true,
                                            errorBuilder: (_, _, _) => Container(color: _igElevated));
                                        },
                                      ),
                              ),
                            );
                          },
                        ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('Powered by GIPHY', style: TextStyle(color: _igMuted, fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}
