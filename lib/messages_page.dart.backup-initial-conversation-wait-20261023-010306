import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/chat_controller.dart';
import 'data/chat_media.dart';
import 'data/inbox_controller.dart';
import 'data/local_cache.dart';
import 'data/social_repository.dart';
import 'data/twice_media.dart';
import 'widgets/skeleton.dart';

// Design tokens (match main.dart dark IG theme)
const _igBlack = Color(0xFF000000);
const _igSurface = Color(0xFF121212);
const _igElevated = Color(0xFF262626);
const _igBlue = Color(0xFF0095F6);
const _igMuted = Color(0xFFA8A8A8);
const _igBubbleMe = Color(0xFF3797F0);
const _igBubbleThem = Color(0xFF262626);
const _igPlaceholder = Color(0xFF1C1C1E);

/// Stable image provider. Network images are keyed by their storage path (not
/// by the signed-URL token), cached on disk and decoded at a small size, so
/// avatars never blink when a signed URL is refreshed.
ImageProvider<Object>? _avatarProvider(
  String? source, {
  int maxDimension = 256,
}) {
  final v = (source ?? '').trim();
  if (v.isEmpty) return null;
  if (v.startsWith('file://')) {
    return ResizeImage.resizeIfNeeded(
      maxDimension,
      null,
      FileImage(File.fromUri(Uri.parse(v))),
    );
  }
  if (v.startsWith('/')) {
    return ResizeImage.resizeIfNeeded(maxDimension, null, FileImage(File(v)));
  }
  if (v.startsWith('http')) {
    return TwiceNetworkImage(v, maxDimension: maxDimension);
  }
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

DateTime? _asDate(dynamic v) {
  if (v is DateTime) return v;
  if (v == null) return null;
  return DateTime.tryParse(v.toString());
}

// =============================================================================
// INBOX (Messages list) — stale-while-revalidate, live, never flashes a loader
// =============================================================================

class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key, this.initialConversationId});

  /// Optional deep-link target from a tapped push/system notification.
  final String? initialConversationId;

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  // Survives leaving/re-opening the page, so the inbox paints instantly.
  static String _memoryOwner = '';
  static List<Map<String, dynamic>> _memoryRows = [];
  static const _cacheType = 'inbox_rows_v2';

  List<Map<String, dynamic>> _rows = [];
  bool _loading = true; // only true while there is nothing at all to show
  String? _error;
  bool _refreshing = false;
  Timer? _debounce;
  RealtimeChannel? _channel;
  final _search = TextEditingController();

  String get _uid => Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    InboxController.instance.viewing = true;
    InboxController.instance.markAllRead();
    if (_memoryOwner == _uid && _memoryRows.isNotEmpty) {
      _rows = List<Map<String, dynamic>>.of(_memoryRows);
      _loading = false;
    }
    _listen();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    InboxController.instance.viewing = false;
    _debounce?.cancel();
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
    _search.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (_rows.isEmpty && _uid.isNotEmpty) {
      try {
        final raw = await LocalCache.instance.get(_uid, _cacheType);
        if (raw is List && raw.isNotEmpty && mounted && _rows.isEmpty) {
          setState(() {
            _rows = [
              for (final e in raw)
                if (e is Map) Map<String, dynamic>.from(e),
            ];
            _loading = false;
          });
        }
      } catch (_) {}
    }
    await _refresh();
    await _openInitialConversationIfRequested();
  }

  bool _initialConversationHandled = false;

  Future<void> _openInitialConversationIfRequested() async {
    if (_initialConversationHandled) return;
    final target = (widget.initialConversationId ?? '').trim();
    if (target.isEmpty) return;
    _initialConversationHandled = true;
    // Inbox refresh may not include a new conversation immediately; retry once
    // after a short bounded delay, without creating a navigation loop.
    Map<String, dynamic>? row;
    for (final candidate in _rows) {
      if ((candidate['conversation_id'] ?? '').toString() == target) {
        row = candidate;
        break;
      }
    }
    if (row == null) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      await _refresh();
      for (final candidate in _rows) {
        if ((candidate['conversation_id'] ?? '').toString() == target) {
          row = candidate;
          break;
        }
      }
    }
    if (!mounted || row == null) return;
    await _openConversationRow(row);
  }

  Future<void> _openConversationRow(Map<String, dynamic> r) async {
    final convId = (r['conversation_id'] ?? '').toString();
    if (convId.isEmpty || !mounted) return;
    _markLocalRead(convId);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          conversationId: convId,
          title: (r['other_name'] ?? r['other_username'] ?? 'Chat').toString(),
          otherUserId: (r['other_user_id'] ?? '').toString(),
          otherAvatar: (r['other_avatar'] ?? '').toString(),
          otherUsername: (r['other_username'] ?? '').toString(),
        ),
      ),
    );
  }

  void _listen() {
    if (_uid.isEmpty) return;
    _channel = Supabase.instance.client
        .channel('inbox-live-$_uid-${DateTime.now().microsecondsSinceEpoch}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload) =>
              _onMessage(Map<String, dynamic>.from(payload.newRecord)),
        )
        .subscribe();
  }

  /// Patches the row in place (instant) instead of reloading the inbox.
  void _onMessage(Map<String, dynamic> row) {
    if (!mounted) return;
    final convId = (row['conversation_id'] ?? '').toString();
    final idx = _rows.indexWhere(
      (r) => (r['conversation_id'] ?? '').toString() == convId,
    );
    if (idx < 0) {
      _refreshSoon(); // brand-new conversation
      return;
    }
    final sender = (row['sender_id'] ?? '').toString();
    final open = InboxController.instance.activeConversationId == convId;
    final updated = Map<String, dynamic>.from(_rows[idx]);
    updated['last_body'] = (row['body'] ?? '').toString();
    updated['last_media_type'] = (row['media_type'] ?? '').toString();
    updated['last_at'] = _asDate(row['created_at']) ?? DateTime.now();
    updated['unread'] = sender != _uid && !open;
    final next = List<Map<String, dynamic>>.of(_rows)..removeAt(idx);
    next.insert(0, updated);
    setState(() => _rows = next);
    _remember(next);
  }

  void _refreshSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _refresh);
  }

  void _remember(List<Map<String, dynamic>> rows) {
    _memoryOwner = _uid;
    _memoryRows = rows;
    if (_uid.isEmpty) return;
    final serial = [
      for (final r in rows)
        {...r, 'last_at': _asDate(r['last_at'])?.toIso8601String()},
    ];
    unawaited(
      LocalCache.instance
          .put(_uid, _cacheType, serial)
          .catchError((Object _) {}),
    );
  }

  /// Silent refresh: updates rows in place; the skeleton only ever shows when
  /// the inbox has never loaded before.
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final rows = await SocialRepository.instance.conversationsDetailed();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
        _error = null;
      });
      _remember(rows);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_rows.isEmpty) _error = e.toString();
        _loading = false;
      });
    } finally {
      _refreshing = false;
    }
  }

  void _markLocalRead(String convId) {
    final idx = _rows.indexWhere(
      (r) => (r['conversation_id'] ?? '').toString() == convId,
    );
    if (idx < 0 || _rows[idx]['unread'] != true) return;
    final updated = Map<String, dynamic>.from(_rows[idx])..['unread'] = false;
    setState(() {
      _rows = List<Map<String, dynamic>>.of(_rows)..[idx] = updated;
    });
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Open a profile and tap Message to start a chat',
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
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
    if (_loading && _rows.isEmpty) return const InboxSkeleton();
    if (_error != null && _rows.isEmpty) {
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
              TextButton(onPressed: _refresh, child: const Text('Retry')),
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
      onRefresh: _refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: list.length,
        itemBuilder: (_, i) {
          final r = list[i];
          final convId = r['conversation_id'].toString();
          return _ConversationTile(
            key: ValueKey<String>('conv-$convId'),
            data: r,
            onOpen: () async {
              await _openConversationRow(r);
              // Quiet re-sync in the background; the list stays on screen.
              if (mounted) unawaited(_refresh());
            },
          );
        },
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    super.key,
    required this.data,
    required this.onOpen,
  });
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
    final lastAt = _asDate(data['last_at']);

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
// CONVERSATION (Messenger / Telegram style chat room)
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
  late final ImageProvider<Object>? _peerAvatar;
  bool _stickToBottom = true;
  bool _showJump = false;
  int _unseen = 0;
  int _lastCount = 0;
  String _lastTailKey = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    InboxController.instance.activeConversationId = widget.conversationId;
    _peerAvatar = _avatarProvider(widget.otherAvatar);
    _chat = ChatController.obtain(widget.conversationId);
    final msgs = _chat.messages;
    _lastCount = msgs.length;
    _lastTailKey = msgs.isEmpty ? '' : msgs.last.clientId;
    _chat.addListener(_onChatChanged);
    _scroll.addListener(_onScroll);
    unawaited(
      _chat.attach(
        peerUserId: widget.otherUserId.isEmpty ? null : widget.otherUserId,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _chat.setForeground(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _chat.setForeground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chat.removeListener(_onChatChanged);
    // The chat session keeps running (e.g. an upload in progress); we only
    // stop listening and release realtime.
    _chat.detach();
    if (InboxController.instance.activeConversationId ==
        widget.conversationId) {
      InboxController.instance.activeConversationId = null;
    }
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    // reverse:true → pixels near 0 means the newest messages are in view.
    final atBottom = pos.pixels < 80;
    if (atBottom != _stickToBottom || (atBottom && _unseen > 0)) {
      setState(() {
        _stickToBottom = atBottom;
        _showJump = !atBottom;
        if (atBottom) _unseen = 0;
      });
    }
    if (pos.pixels > pos.maxScrollExtent - 500) {
      unawaited(_chat.loadOlder());
    }
  }

  void _onChatChanged() {
    if (!mounted) return;
    final msgs = _chat.messages;
    final count = msgs.length;
    final tailKey = count == 0 ? '' : msgs.last.clientId;
    final appended = count > _lastCount && tailKey != _lastTailKey;
    if (appended) {
      final tail = msgs.last;
      if (tail.isMine || _stickToBottom) {
        _scrollToNewest();
      } else {
        _unseen++;
        _showJump = true;
      }
    }
    _lastCount = count;
    _lastTailKey = tailKey;
    setState(() {});
  }

  void _scrollToNewest({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (jump) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _sendText() {
    final body = _text.text.trim();
    if (body.isEmpty) return;
    _text.clear();
    _stickToBottom = true;
    unawaited(HapticFeedback.lightImpact());
    unawaited(SystemSound.play(SystemSoundType.click).catchError((_) {}));
    // Optimistic: the bubble appears immediately; failures show on the bubble.
    unawaited(_chat.sendText(body));
    _scrollToNewest();
  }

  Future<void> _openGifPicker() async {
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
      unawaited(_chat.sendMediaFile(file: file, mediaType: 'image'));
      _scrollToNewest();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not send GIF: $e')));
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
                          : () =>
                                Navigator.pop(sheetContext, List.of(selected)),
                      child: const Text('Send'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: assets.length,
                  itemBuilder: (_, index) {
                    final item = assets[index];
                    final isSelected = selected.contains(item);
                    return GestureDetector(
                      key: ValueKey<String>('asset-${item.id}'),
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
                          _AssetThumb(asset: item),
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
        unawaited(_chat.sendMediaFile(file: file, mediaType: 'video'));
      } else if (chosen.length == 1) {
        final file = await chosen.first.file;
        if (file == null) throw StateError('Could not open photo');
        unawaited(_chat.sendMediaFile(file: file, mediaType: 'image'));
      } else {
        final files = <File>[];
        for (final a in chosen) {
          final f = await a.file;
          if (f != null) files.add(f);
        }
        if (files.isEmpty) throw StateError('Could not open photos');
        unawaited(_chat.sendMediaAlbum(files));
      }
      _scrollToNewest();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not send media: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final String subtitle;
    final Color subtitleColor;
    if (_chat.otherTyping) {
      subtitle = 'typing…';
      subtitleColor = _igBlue;
    } else if (_chat.otherOnline) {
      subtitle = 'Active now';
      subtitleColor = const Color(0xFF31A24C);
    } else if (_chat.otherLastSeen != null) {
      subtitle = 'Active ${_relativeTime(_chat.otherLastSeen)}';
      subtitleColor = _igMuted;
    } else {
      subtitle = widget.otherUsername.isNotEmpty
          ? '@${widget.otherUsername}'
          : '';
      subtitleColor = _igMuted;
    }

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
              backgroundImage: _peerAvatar,
              child: _peerAvatar == null
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
                      style: TextStyle(color: subtitleColor, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _buildMessageList()),
                if (_showJump)
                  Positioned(
                    right: 14,
                    bottom: 12,
                    child: _JumpToLatest(
                      count: _unseen,
                      onTap: () {
                        setState(() {
                          _unseen = 0;
                          _showJump = false;
                          _stickToBottom = true;
                        });
                        _scrollToNewest();
                      },
                    ),
                  ),
              ],
            ),
          ),
          _composer(),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    final msgs = _chat.messages;

    if (_chat.loading && msgs.isEmpty) return const ChatSkeleton();
    if (_chat.error != null && msgs.isEmpty) {
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
                onPressed: () => _chat.syncSilently(initial: true),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (msgs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: _igElevated,
              backgroundImage: _peerAvatar,
              child: _peerAvatar == null
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

    final total = msgs.length;
    final indexByKey = <String, int>{
      for (var i = 0; i < total; i++) msgs[i].clientId: total - 1 - i,
    };
    final extra = _chat.loadingOlder ? 1 : 0;

    // reverse:true keeps the newest message pinned to the bottom; rows are
    // keyed by a stable clientId so inserts never rebuild existing bubbles.
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      itemCount: total + extra,
      findChildIndexCallback: (Key key) {
        if (key is ValueKey<String>) return indexByKey[key.value];
        return null;
      },
      itemBuilder: (_, i) {
        if (i >= total) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _igMuted,
                ),
              ),
            ),
          );
        }
        final index = total - 1 - i; // i == 0 is the newest
        final m = msgs[index];
        final prev = index > 0 ? msgs[index - 1] : null;
        final showAvatar =
            !m.isMine && (prev == null || prev.senderId != m.senderId);
        final showDay =
            prev == null ||
            !_sameDay(prev.createdAt.toLocal(), m.createdAt.toLocal());
        return _ChatBubble(
          key: ValueKey<String>(m.clientId),
          message: m,
          showAvatar: showAvatar,
          showDay: showDay,
          avatar: _peerAvatar,
          isRead: _chat.isRead(m),
          animate: _chat.isFresh(m),
          onRetry: m.status == ChatSendStatus.failed
              ? () => unawaited(_chat.retry(m))
              : null,
          onDiscard: m.status == ChatSendStatus.failed
              ? () => _chat.discard(m)
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
              onPressed: () => _pickAndSendMedia(video: false),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: _igSurface,
                  border: Border.all(
                    color: const Color(0xFF303030),
                    width: 0.7,
                  ),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onChanged: (v) =>
                            _chat.notifyTyping(v.trim().isNotEmpty),
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
                      icon: const Icon(
                        Icons.image_outlined,
                        color: _igMuted,
                        size: 22,
                      ),
                      onPressed: () => _pickAndSendMedia(video: false),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: 'Video',
                      icon: const Icon(
                        Icons.videocam_outlined,
                        color: _igMuted,
                        size: 22,
                      ),
                      onPressed: () => _pickAndSendMedia(video: true),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: 'GIF',
                      icon: const Icon(
                        Icons.gif_box_outlined,
                        color: _igMuted,
                        size: 24,
                      ),
                      onPressed: _openGifPicker,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.send_rounded, color: _igBlue),
              onPressed: _sendText,
            ),
          ],
        ),
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayLabel(DateTime d) {
  final now = DateTime.now();
  if (_sameDay(d, now)) return 'Today';
  if (_sameDay(d, now.subtract(const Duration(days: 1)))) return 'Yesterday';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}';
}

class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: _igElevated,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF3A3A3A), width: 0.7),
            ),
            child: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          if (count > 0)
            Positioned(
              right: -4,
              top: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _igBlue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Gallery thumbnail whose future is created ONCE per tile. (The old picker
/// recreated the future on every selection tap, so thumbnails flashed black.)
class _AssetThumb extends StatefulWidget {
  const _AssetThumb({required this.asset});
  final AssetEntity asset;

  @override
  State<_AssetThumb> createState() => _AssetThumbState();
}

class _AssetThumbState extends State<_AssetThumb> {
  late final Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.asset.thumbnailDataWithSize(const ThumbnailSize(240, 240));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return const ColoredBox(color: Color(0xFF1A1A1A));
        return Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}

// =============================================================================
// Bubble
// =============================================================================

/// Plays the enter animation once per message, and never for history or for
/// bubbles that are merely scrolled back into view.
class _EnterAnimation extends StatefulWidget {
  const _EnterAnimation({
    required this.id,
    required this.animate,
    required this.own,
    required this.child,
  });

  final String id;
  final bool animate;
  final bool own;
  final Widget child;

  @override
  State<_EnterAnimation> createState() => _EnterAnimationState();
}

class _EnterAnimationState extends State<_EnterAnimation>
    with SingleTickerProviderStateMixin {
  static final Set<String> _played = <String>{};
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (_played.length > 600) _played.clear();
    if (widget.animate && _played.add(widget.id)) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 220),
      )..forward();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return widget.child;
    return AnimatedBuilder(
      animation: c,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(
              widget.own ? 16 * (1 - t) : -10 * (1 - t),
              10 * (1 - t),
            ),
            child: child,
          ),
        );
      },
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    super.key,
    required this.message,
    required this.showAvatar,
    required this.showDay,
    required this.avatar,
    required this.isRead,
    required this.animate,
    this.onRetry,
    this.onDiscard,
  });

  final ChatMessage message;
  final bool showAvatar;
  final bool showDay;
  final ImageProvider<Object>? avatar;
  final bool isRead;
  final bool animate;
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final own = m.isMine;
    final body = m.body;
    final createdAt = m.createdAt.toLocal();
    final timeLabel =
        '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';

    final atts = m.attachments
        .where((a) => a.mediaUrl.isNotEmpty || (a.localPath ?? '').isNotEmpty)
        .toList();
    final isAlbum = atts.length > 1;
    final single = atts.length == 1 ? atts.first : null;
    final storagePath = (single != null && single.mediaUrl.isNotEmpty)
        ? single.mediaUrl
        : (m.mediaUrl ?? '');
    final localPath = (m.localFilePath ?? '').isNotEmpty
        ? m.localFilePath!
        : (single?.localPath ?? '');
    final isVideo = (single?.mediaType ?? m.mediaType) == 'video';
    final hasSingle =
        !isAlbum && (storagePath.isNotEmpty || localPath.isNotEmpty);
    final hasMedia = isAlbum || hasSingle;

    Widget? media;
    if (isAlbum) {
      media = _AlbumGrid(attachments: atts);
    } else if (hasSingle) {
      media = isVideo
          ? _ChatVideo(
              key: ValueKey<String>('media-${m.clientId}'),
              storagePath: storagePath,
              localPath: localPath,
              width: 220,
              height: 280,
            )
          : _ChatImage(
              key: ValueKey<String>('media-${m.clientId}'),
              storagePath: storagePath,
              localPath: localPath,
              width: 220,
              height: 280,
            );
    }
    if (media != null) {
      media = Stack(
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(14), child: media),
          if (m.status == ChatSendStatus.sending)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: const ColoredBox(
                  color: Color(0x66000000),
                  child: Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    final Widget? statusIcon;
    if (!own) {
      statusIcon = null;
    } else if (m.status == ChatSendStatus.sending) {
      statusIcon = const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 1.4,
          color: Colors.white70,
        ),
      );
    } else if (m.status == ChatSendStatus.failed) {
      statusIcon = const Icon(
        Icons.error_outline,
        size: 14,
        color: Colors.redAccent,
      );
    } else {
      statusIcon = Icon(
        isRead ? Icons.done_all : Icons.done,
        size: 14,
        color: isRead ? const Color(0xFF34B7F1) : Colors.white70,
      );
    }

    final bubble = Padding(
      padding: EdgeInsets.only(
        top: showAvatar ? 10 : 2,
        bottom: 2,
        left: own ? 48 : 0,
        right: own ? 0 : 48,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: own
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!own) ...[
            if (showAvatar)
              CircleAvatar(
                radius: 14,
                backgroundColor: _igElevated,
                backgroundImage: avatar,
                child: avatar == null
                    ? const Icon(Icons.person, size: 14, color: _igMuted)
                    : null,
              )
            else
              const SizedBox(width: 28),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: own
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: onRetry,
                  onLongPress: onDiscard,
                  child: Container(
                    padding: hasMedia
                        ? const EdgeInsets.all(4)
                        : const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
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
                        ?media,
                        if (body.trim().isNotEmpty) ...[
                          if (hasMedia) const SizedBox(height: 6),
                          Padding(
                            padding: hasMedia
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
                ),
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (m.status == ChatSendStatus.failed)
                      const Text(
                        'Not sent · tap to retry · hold to delete  ',
                        style: TextStyle(color: Colors.redAccent, fontSize: 10),
                      )
                    else
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
    );

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showDay)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text(
                  _dayLabel(createdAt),
                  style: const TextStyle(color: _igMuted, fontSize: 11.5),
                ),
              ),
            ),
          _EnterAnimation(
            id: m.clientId,
            animate: animate,
            own: own,
            child: bubble,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Media widgets (stable, cached, never blank)
// =============================================================================

/// Shows a chat photo/GIF from a LOCAL file. The file is found by the STORAGE
/// PATH (stable) or the original picked file, never by a signed URL, so
/// refreshes/reconnects can never make it reload or go black.
class _ChatImage extends StatefulWidget {
  const _ChatImage({
    super.key,
    required this.storagePath,
    required this.localPath,
    required this.width,
    required this.height,
  });

  final String storagePath;
  final String localPath;
  final double width;
  final double height;

  @override
  State<_ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends State<_ChatImage> {
  String? _file;
  bool _failed = false;
  bool _recovered = false;
  int _generation = 0;

  String? _initial() {
    final lp = widget.localPath;
    if (lp.isNotEmpty && File(lp).existsSync()) return lp;
    if (widget.storagePath.isNotEmpty) {
      return ChatMediaStore.instance.localSync(widget.storagePath);
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _file = _initial();
    if (_file == null) unawaited(_resolve());
  }

  @override
  void didUpdateWidget(covariant _ChatImage old) {
    super.didUpdateWidget(old);
    if (old.storagePath == widget.storagePath &&
        old.localPath == widget.localPath) {
      return;
    }
    // Keep the picture that is already on screen; only swap if we have a
    // different source ready right now.
    final next = _initial();
    if (next != null) {
      _file = next;
    } else if (_file == null) {
      unawaited(_resolve());
    }
  }

  Future<void> _resolve({int attempt = 0}) async {
    final path = widget.storagePath;
    if (path.isEmpty) return;
    final gen = ++_generation;
    final f = await ChatMediaStore.instance.local(path);
    if (!mounted || gen != _generation) return;
    if (f != null) {
      setState(() {
        _file = f;
        _failed = false;
      });
      return;
    }
    setState(() => _failed = true);
    if (attempt < 2) {
      Future<void>.delayed(Duration(seconds: 4 * (attempt + 1)), () {
        if (!mounted || _file != null) return;
        setState(() => _failed = false);
        unawaited(_resolve(attempt: attempt + 1));
      });
    }
  }

  void _recoverFromBadFile() {
    if (_recovered) return;
    _recovered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final path = widget.storagePath;
      if (path.isEmpty) return;
      await ChatMediaStore.instance.forget(path);
      if (!mounted) return;
      setState(() => _file = null);
      unawaited(_resolve());
    });
  }

  Widget _placeholder() {
    return GestureDetector(
      onTap: _failed ? () => unawaited(_resolve()) : null,
      child: ColoredBox(
        color: _igPlaceholder,
        child: Center(
          child: _failed
              ? const Icon(Icons.refresh_rounded, color: _igMuted, size: 26)
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final Widget content;
    if (file == null) {
      content = _placeholder();
    } else {
      content = Image(
        image: ResizeImage.resizeIfNeeded(
          (widget.width * dpr).round(),
          null,
          FileImage(File(file)),
        ),
        fit: BoxFit.cover,
        width: widget.width,
        height: widget.height,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, wasSync) {
          if (wasSync) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 160),
            child: child,
          );
        },
        errorBuilder: (_, _, _) {
          _recoverFromBadFile();
          return _placeholder();
        },
      );
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ColoredBox(color: _igPlaceholder, child: content),
    );
  }
}

/// Video bubble: always shows a real frame (generated once and cached on
/// disk), with a play icon. Reuses the same poster engine as the feed.
class _ChatVideo extends StatefulWidget {
  const _ChatVideo({
    super.key,
    required this.storagePath,
    required this.localPath,
    required this.width,
    required this.height,
  });

  final String storagePath;
  final String localPath;
  final double width;
  final double height;

  @override
  State<_ChatVideo> createState() => _ChatVideoState();
}

class _ChatVideoState extends State<_ChatVideo> {
  String? _url;

  @override
  void initState() {
    super.initState();
    final lp = widget.localPath;
    if (lp.isNotEmpty && File(lp).existsSync()) {
      _url = Uri.file(lp).toString();
    } else {
      unawaited(_resolve());
    }
  }

  Future<void> _resolve() async {
    final path = widget.storagePath;
    if (path.isEmpty) return;
    final signed = await ChatMediaStore.instance.signedUrl(path);
    if (!mounted || _url != null) return;
    setState(() {
      // Offline fallback: same stable key, so an already-cached poster shows.
      _url =
          signed ??
          'https://offline.invalid/storage/v1/object/sign/chat-media/$path';
    });
  }

  @override
  void didUpdateWidget(covariant _ChatVideo old) {
    super.didUpdateWidget(old);
    if (_url == null && old.storagePath != widget.storagePath) {
      unawaited(_resolve());
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: url == null
          ? const ColoredBox(
              color: _igPlaceholder,
              child: Center(
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white54,
                  size: 48,
                ),
              ),
            )
          : TwiceVideoPoster(
              videoUrl: url,
              thumbnailUrl: '',
              imageProviderFor: (s) => TwiceNetworkImage(s),
              fit: BoxFit.cover,
            ),
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.attachments});
  final List<ChatAttachment> attachments;

  Widget _cell(int i, double w, double h) {
    final a = attachments[i];
    return _ChatImage(
      key: ValueKey<int>(a.position),
      storagePath: a.mediaUrl,
      localPath: a.localPath ?? '',
      width: w,
      height: h,
    );
  }

  @override
  Widget build(BuildContext context) {
    const total = 220.0;
    const gap = 2.0;
    const half = (total - gap) / 2;
    final n = attachments.length;

    final Widget grid;
    if (n == 2) {
      grid = Row(
        children: [
          _cell(0, half, 150),
          const SizedBox(width: gap),
          _cell(1, half, 150),
        ],
      );
    } else if (n == 3) {
      grid = Column(
        children: [
          _cell(0, total, 140),
          const SizedBox(height: gap),
          Row(
            children: [
              _cell(1, half, half),
              const SizedBox(width: gap),
              _cell(2, half, half),
            ],
          ),
        ],
      );
    } else {
      final more = n - 4;
      grid = Column(
        children: [
          Row(
            children: [
              _cell(0, half, half),
              const SizedBox(width: gap),
              _cell(1, half, half),
            ],
          ),
          const SizedBox(height: gap),
          Row(
            children: [
              _cell(2, half, half),
              const SizedBox(width: gap),
              Stack(
                children: [
                  _cell(3, half, half),
                  if (more > 0)
                    Positioned.fill(
                      child: ColoredBox(
                        color: const Color(0x99000000),
                        child: Center(
                          child: Text(
                            '+$more',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      );
    }
    return SizedBox(width: total, child: grid);
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
    } catch (_) {
      return null;
    }
  }

  Future<void> cachePreview(String url) async {
    try {
      if (await cachedPreview(url) != null) return;
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
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
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw HttpException('GIPHY returned ${response.statusCode}');
      }
      await target.writeAsBytes(response.bodyBytes, flush: true);
      return target;
    } catch (_) {
      // If offline, send the already-cached animated preview for this GIF.
      final previewUrl =
          (images['fixed_width'] as Map?)?['url']?.toString() ??
          (images['preview_gif'] as Map?)?['url']?.toString();
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
          ? decoded
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
          : [];
    } catch (_) {
      return [];
    }
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
      setState(() {
        _gifs = cached;
        _loading = false;
      });
    }
    await _fetch('');
  }

  Future<void> _fetch(String query) async {
    if (!mounted) return;
    setState(() {
      _loading = _gifs.isEmpty;
      _error = null;
    });
    try {
      final endpoint = query.isEmpty ? 'trending' : 'search';
      final uri = Uri.https('api.giphy.com', '/v1/gifs/$endpoint', {
        'api_key': _giphyApiKey,
        'limit': '40',
        'rating': 'pg-13',
        if (query.isNotEmpty) 'q': query,
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw HttpException('GIPHY ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final data = (decoded['data'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      setState(() {
        _gifs = data;
        _loading = false;
      });
      if (query.isEmpty) await _TwiceGifCache.instance.saveResults(data);
      for (final gif in data.take(18)) {
        final images = gif['images'] as Map? ?? const {};
        final preview =
            (images['fixed_width'] as Map?)?['url']?.toString() ??
            (images['preview_gif'] as Map?)?['url']?.toString();
        if (preview != null && preview.isNotEmpty) {
          unawaited(_TwiceGifCache.instance.cachePreview(preview));
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Offline: showing cached GIFs';
        });
      }
    }
  }

  String? _previewUrl(Map<String, dynamic> gif) {
    final images = gif['images'] as Map? ?? const {};
    return (images['fixed_width'] as Map?)?['url']?.toString() ??
        (images['preview_gif'] as Map?)?['url']?.toString();
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
              child: Row(
                children: [
                  const Text(
                    'GIFs',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
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
                  filled: true,
                  fillColor: const Color(0xFF242424),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: _igMuted, fontSize: 12),
                ),
              ),
            Expanded(
              child: _loading && _gifs.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(color: _igBlue),
                    )
                  : _gifs.isEmpty
                  ? const Center(
                      child: Text(
                        'No GIFs found',
                        style: TextStyle(color: _igMuted),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 6,
                            crossAxisSpacing: 6,
                            childAspectRatio: 1.15,
                          ),
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
                                : _GifTile(
                                    key: ValueKey<String>(preview),
                                    previewUrl: preview,
                                  ),
                          ),
                        );
                      },
                    ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Powered by GIPHY',
                style: TextStyle(color: _igMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GifTile extends StatefulWidget {
  const _GifTile({super.key, required this.previewUrl});
  final String previewUrl;

  @override
  State<_GifTile> createState() => _GifTileState();
}

class _GifTileState extends State<_GifTile> {
  late final Future<File?> _cached;

  @override
  void initState() {
    super.initState();
    _cached = _TwiceGifCache.instance.cachedPreview(widget.previewUrl);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _cached,
      builder: (_, snap) {
        if (snap.data != null) {
          return Image.file(
            snap.data!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        }
        return Image.network(
          widget.previewUrl,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Container(color: _igElevated),
        );
      },
    );
  }
}
