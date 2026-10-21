import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import 'data/inbox_controller.dart';
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

class _ConversationPageState extends State<ConversationPage> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _sending = false;
  String? _error;
  RealtimeChannel? _channel;
  final Map<String, Map<String, dynamic>> _senderCache = {};
  bool _attachmentRefreshScheduled = false;

  void _scheduleAttachmentRefresh() {
    if (_attachmentRefreshScheduled) return;
    _attachmentRefreshScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      _attachmentRefreshScheduled = false;
      if (mounted) unawaited(_refreshMessagesQuietly());
    });
  }

  String get _myId => Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    _load();
    _subscribe();
    InboxController.instance.markConversationRead(widget.conversationId);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    final ch = _channel;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
    super.dispose();
  }

  void _subscribe() {
    _channel = Supabase.instance.client
        .channel('chat-${widget.conversationId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: widget.conversationId,
          ),
          callback: (payload) {
            final row = Map<String, dynamic>.from(payload.newRecord);
            if (_messages.any((m) => m['id'] == row['id'])) return;
            unawaited(_refreshMessagesQuietly());
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_attachments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: widget.conversationId,
          ),
          callback: (_) => _scheduleAttachmentRefresh(),
        )
        .subscribe();
  }

  Future<void> _refreshMessagesQuietly() async {
    try {
      final rows = await SocialRepository.instance
          .messagesDetailed(widget.conversationId);
      if (!mounted) return;

      for (final r in rows) {
        final sid = (r['sender_id'] ?? '').toString();
        final profile = r['sender_profile'];
        if (sid.isNotEmpty && profile is Map) {
          _senderCache[sid] = Map<String, dynamic>.from(profile);
        }
      }

      // Merge server rows with pending local bubbles. Never show the loading
      // skeleton during a background refresh.
      final merged = List<Map<String, dynamic>>.from(rows);
      final pending = _messages.where(
        (m) => (m['id'] ?? '').toString().startsWith('local-'),
      );

      for (final local in pending) {
        final localId = (local['id'] ?? '').toString();
        final localTime = DateTime.tryParse(
          (local['created_at'] ?? '').toString(),
        );
        final confirmed = merged.any((m) {
          final serverTime = DateTime.tryParse(
            (m['created_at'] ?? '').toString(),
          );
          return (m['sender_id'] ?? '').toString() ==
                  (local['sender_id'] ?? '').toString() &&
              (m['body'] ?? '').toString() ==
                  (local['body'] ?? '').toString() &&
              serverTime != null &&
              localTime != null &&
              serverTime.difference(localTime).inSeconds.abs() < 120;
        });

        if (confirmed) {
          final matchIndex = merged.indexWhere((m) {
            final serverTime = DateTime.tryParse(
              (m['created_at'] ?? '').toString(),
            );
            return (m['sender_id'] ?? '').toString() ==
                    (local['sender_id'] ?? '').toString() &&
                (m['body'] ?? '').toString() ==
                    (local['body'] ?? '').toString() &&
                serverTime != null &&
                localTime != null &&
                serverTime.difference(localTime).inSeconds.abs() < 120;
          });
          if (matchIndex >= 0) {
            merged[matchIndex]['_ui_id'] = localId;
          }
        } else if (!merged.any((m) => (m['id'] ?? '').toString() == localId)) {
          merged.add(local);
        }
      }

      merged.sort((a, b) {
        final at = DateTime.tryParse((a['created_at'] ?? '').toString()) ??
            DateTime(1970);
        final bt = DateTime.tryParse((b['created_at'] ?? '').toString()) ??
            DateTime(1970);
        return at.compareTo(bt);
      });

      final oldIds = _messages.map((m) => '${m['id']}').join('|');
      final newIds = merged.map((m) => '${m['id']}').join('|');
      if (oldIds != newIds) {
        setState(() => _messages = merged);
        _scrollToBottom();
      }

      InboxController.instance.markConversationRead(widget.conversationId);
    } catch (_) {
      // Background refresh failures must not interrupt the visible chat.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await SocialRepository.instance
          .messagesDetailed(widget.conversationId);
      if (!mounted) return;
      // Pre-cache sender profiles that came back
      for (final r in rows) {
        final sid = (r['sender_id'] ?? '').toString();
        final p = r['sender_profile'];
        if (sid.isNotEmpty && p is Map) {
          _senderCache[sid] = Map<String, dynamic>.from(p);
        }
      }
      setState(() {
        _messages = rows;
        _loading = false;
      });
      _scrollToBottom(jump: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
        // Recheck after the list finishes laying out the newest bubble.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final latest = _scroll.position.maxScrollExtent;
          if ((_scroll.position.pixels - latest).abs() > 24) {
            _scroll.animateTo(
              latest,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
            );
          }
        });
      }
    });
  }

  Future<void> _sendText() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _sending) return;

    final now = DateTime.now().toUtc();
    final localId = 'local-${now.microsecondsSinceEpoch}';
    final optimistic = <String, dynamic>{
      'id': localId,
      '_ui_id': localId,
      'conversation_id': widget.conversationId,
      'sender_id': _myId,
      'body': body,
      'media_url': null,
      'media_type': null,
      'created_at': now.toIso8601String(),
    };

    // Display and animate immediately; do not wait for Supabase.
    setState(() {
      _sending = true;
      _messages = [..._messages, optimistic];
    });
    _scrollToBottom();
    unawaited(SystemSound.play(SystemSoundType.click).catchError((_) {}));

    try {
      await SocialRepository.instance.sendMessage(
        widget.conversationId,
        body,
      );
      if (!mounted) return;
      _controller.clear();
      // Confirm in the background; Realtime and this refresh are deduplicated.
      unawaited(_refreshMessagesQuietly());
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.removeWhere((m) => m['id'] == localId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }


  Future<void> _captureFromCamera() async {
    if (_sending) return;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
      );
      if (picked == null || !mounted) return;
      setState(() => _sending = true);
      await SocialRepository.instance.sendMediaMessage(
        conversationId: widget.conversationId,
        file: File(picked.path),
        mediaType: 'image',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openGifPicker() async {
    if (_sending) return;
    final gif = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _igSurface,
      builder: (_) => const _TwiceGifPicker(),
    );
    if (gif == null || !mounted) return;
    setState(() => _sending = true);
    try {
      final file = await _TwiceGifCache.instance.downloadGif(gif);
      await SocialRepository.instance.sendMediaMessage(
        conversationId: widget.conversationId,
        file: file,
        mediaType: 'image',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send GIF: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
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

    final assets = await paths.first.getAssetListPaged(page: 0, size: 100);
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
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (!video)
                      TextButton(
                        onPressed: selected.isEmpty
                            ? null
                            : () => Navigator.pop(
                                  sheetContext,
                                  List<AssetEntity>.from(selected),
                                ),
                        child: const Text('Next'),
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
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: assets.length,
                  itemBuilder: (_, index) {
                    final asset = assets[index];
                    final isSelected =
                        selected.any((item) => item.id == asset.id);

                    return FutureBuilder<File?>(
                      future: asset.file,
                      builder: (_, snapshot) {
                        final file = snapshot.data;
                        return GestureDetector(
                          onTap: () {
                            if (video) {
                              Navigator.pop(sheetContext, [asset]);
                              return;
                            }

                            setSheetState(() {
                              if (isSelected) {
                                selected.removeWhere(
                                  (item) => item.id == asset.id,
                                );
                              } else if (selected.length < 10) {
                                selected.add(asset);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'You can select up to 10 photos.',
                                    ),
                                  ),
                                );
                              }
                            });
                          },
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (file == null)
                                Container(color: _igElevated)
                              else
                                Image.file(file, fit: BoxFit.cover),
                              if (isSelected)
                                Container(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  alignment: Alignment.topRight,
                                  padding: const EdgeInsets.all(6),
                                  child: CircleAvatar(
                                    radius: 12,
                                    backgroundColor: _igBlue,
                                    child: Text(
                                      '${selected.indexWhere(
                                            (item) => item.id == asset.id,
                                          ) + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              if (video)
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
              if (!video)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.pop(
                                sheetContext,
                                List<AssetEntity>.from(selected),
                              ),
                      child: Text('Send ${selected.length} photo(s)'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (chosen == null || chosen.isEmpty || !mounted) return;

    setState(() => _sending = true);
    try {
      final files = <File>[];
      for (final asset in chosen) {
        final file = await asset.file;
        if (file != null) files.add(file);
      }
      if (files.isEmpty) {
        throw StateError('Could not read the selected media.');
      }

      if (!video && files.length > 1) {
        await SocialRepository.instance.sendMediaAlbum(
          conversationId: widget.conversationId,
          files: files,
        );
      } else {
        await SocialRepository.instance.sendMediaMessage(
          conversationId: widget.conversationId,
          file: files.first,
          mediaType: video ? 'video' : 'image',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final otherProv = _avatarProvider(widget.otherAvatar);

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
              radius: 20,
              backgroundColor: _igElevated,
              backgroundImage: otherProv,
              onBackgroundImageError: otherProv == null
                  ? null
                  : (exception, stackTrace) {},
              child: otherProv == null
                  ? Text(
                      widget.title.isNotEmpty
                          ? widget.title[0].toUpperCase()
                          : '?',
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                    )
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
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  if (widget.otherUsername.isNotEmpty)
                    Text(
                      '@${widget.otherUsername}',
                      style: const TextStyle(color: _igMuted, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.phone_outlined, color: Colors.white),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined, color: Colors.white),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _thread()),
          _composer(),
        ],
      ),
    );
  }

  Widget _thread() {
    if (_loading) return const ChatSkeleton();
    if (_error != null) {
      return Center(
        child: TextButton(onPressed: _load, child: Text('Retry\n$_error')),
      );
    }
    if (_messages.isEmpty) {
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
            const Text(
              'Say hello 👋',
              style: TextStyle(color: _igMuted),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      key: PageStorageKey<String>('twice-chat-${widget.conversationId}'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      itemCount: _messages.length,
      itemBuilder: (_, i) {
        final m = _messages[i];
        final own = (m['sender_id'] ?? '') == _myId;
        final prevOwn = i > 0 &&
            (_messages[i - 1]['sender_id'] ?? '') == (m['sender_id'] ?? '');
        return TweenAnimationBuilder<double>(
          key: ValueKey<String>(
            'chat-message-${m['_ui_id'] ?? m['id'] ?? m['created_at'] ?? i}',
          ),
          tween: Tween<double>(begin: 0, end: 1),
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(own ? 14 * (1 - value) : -8 * (1 - value), 8 * (1 - value)),
              child: child,
            ),
          ),
          child: _Bubble(
            message: m,
            own: own,
            showAvatar: !own && !prevOwn,
            senderProfile: _senderCache[(m['sender_id'] ?? '').toString()],
            fallbackAvatar: widget.otherAvatar,
          ),
        );
      },
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
        decoration: const BoxDecoration(
          color: _igBlack,
          border: Border(top: BorderSide(color: _igElevated, width: 0.5)),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.camera_alt, color: _igBlue),
              onPressed: _sending ? null : _captureFromCamera,
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                decoration: BoxDecoration(
                  color: const Color(0xFF1D1D1D),
                  border: Border.all(color: const Color(0xFF303030), width: 0.7),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        style: const TextStyle(color: Colors.white, fontSize: 15),
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
                      icon: const Icon(Icons.image_outlined, color: _igMuted, size: 22),
                      onPressed:
                          _sending ? null : () => _pickAndSendMedia(video: false),
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      tooltip: 'GIF',
                      icon: const Icon(Icons.gif_box_outlined, color: _igMuted, size: 24),
                      onPressed: _sending ? null : _openGifPicker,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: _sending
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _igBlue,
                      ),
                    )
                  : const Icon(Icons.send_rounded, color: _igBlue),
              onPressed: _sending ? null : _sendText,
            ),
          ],
        ),
      ),
    );
  }
}


// =============================================================================
// GIPHY picker + persistent offline-first cache
// =============================================================================

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

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.own,
    required this.showAvatar,
    this.senderProfile,
    this.fallbackAvatar = '',
  });

  final Map<String, dynamic> message;
  final bool own;
  final bool showAvatar;
  final Map<String, dynamic>? senderProfile;
  final String fallbackAvatar;

  @override
  Widget build(BuildContext context) {
    final body = (message['body'] ?? '').toString();
    final mediaUrl = (message['resolved_media_url'] ??
            message['media_url'] ??
            '')
        .toString();
    final mediaType = (message['media_type'] ?? '').toString();
    final createdAt = DateTime.tryParse(
      (message['created_at'] ?? '').toString(),
    )?.toLocal();
    final timeLabel = createdAt == null
        ? ''
        : '${createdAt.hour.toString().padLeft(2, '0')}:'
          '${createdAt.minute.toString().padLeft(2, '0')}';
    final isRead = own && message['read_at'] != null;
    final hasMedia = mediaUrl.isNotEmpty &&
        (mediaUrl.startsWith('http') || mediaUrl.startsWith('file'));
    final rawAttachments = message['resolved_attachments'];
    final attachments = rawAttachments is List
        ? rawAttachments
            .whereType<Map>()
            .map((a) => Map<String, dynamic>.from(a))
            .where((a) {
              final url = (a['resolved_media_url'] ?? '').toString();
              return url.startsWith('http') || url.startsWith('file');
            })
            .toList()
        : <Map<String, dynamic>>[];
    final hasAlbum = attachments.length > 1;

    final avatarUrl = (senderProfile?['avatar_url'] ?? fallbackAvatar).toString();
    final prov = _avatarProvider(avatarUrl);

    return Padding(
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
                onBackgroundImageError: prov == null
                    ? null
                    : (exception, stackTrace) {},
                child: prov == null
                    ? const Icon(Icons.person, size: 14, color: _igMuted)
                    : null,
              )
            else
              const SizedBox(width: 28),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.72,
              ),
              padding: hasMedia
                  ? EdgeInsets.zero
                  : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: own ? _igBubbleMe : _igBubbleThem,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(own ? 20 : 5),
                  bottomRight: Radius.circular(own ? 5 : 20),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasAlbum)
                    _AlbumGrid(attachments: attachments)
                  else if (hasMedia)
                    _media(mediaUrl, mediaType),
                  if (body.isNotEmpty)
                    Padding(
                      padding: hasMedia
                          ? const EdgeInsets.fromLTRB(12, 8, 12, 10)
                          : EdgeInsets.zero,
                      child: Text(
                        body,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          height: 1.35,
                        ),
                      ),
                    ),
                  if (timeLabel.isNotEmpty || isRead)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        hasMedia ? 8 : 0,
                        6,
                        hasMedia ? 8 : 0,
                        2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (timeLabel.isNotEmpty)
                            Text(
                              timeLabel,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 10,
                              ),
                            ),
                          if (isRead) ...[
                            const SizedBox(width: 6),
                            const Text(
                              'Seen',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _media(String url, String type) {
    if (type == 'video') {
      return _InlineVideo(url: url);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Image(
        image: _avatarProvider(url) ?? const NetworkImage(''),
        fit: BoxFit.cover,
        width: 220,
        height: 280,
        errorBuilder: (_, _, _) => Container(
          width: 220,
          height: 160,
          color: _igElevated,
          alignment: Alignment.center,
          child: const Icon(Icons.broken_image, color: _igMuted),
        ),
      ),
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.attachments});

  final List<Map<String, dynamic>> attachments;

  @override
  Widget build(BuildContext context) {
    final visible = attachments.take(4).toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 240,
        height: visible.length == 2 ? 132 : 220,
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: visible.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemBuilder: (_, index) {
            final item = visible[index];
            final url = (item['resolved_media_url'] ?? '').toString();
            final remaining = attachments.length - 4;

            return Stack(
              fit: StackFit.expand,
              children: [
                Image(
                  image: _avatarProvider(url) ?? const NetworkImage(''),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    color: _igElevated,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.broken_image_outlined,
                      color: _igMuted,
                    ),
                  ),
                ),
                if (index == 3 && remaining > 0)
                  Container(
                    color: Colors.black.withValues(alpha: 0.58),
                    alignment: Alignment.center,
                    child: Text(
                      '+$remaining',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _InlineVideo extends StatefulWidget {
  const _InlineVideo({required this.url});
  final String url;

  @override
  State<_InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends State<_InlineVideo> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    final uri = Uri.parse(widget.url);
    _c = widget.url.startsWith('file')
        ? VideoPlayerController.file(File.fromUri(uri))
        : VideoPlayerController.networkUrl(uri);
    _c!.initialize().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return Container(
        width: 220,
        height: 280,
        color: _igElevated,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        ),
      );
    }
    return GestureDetector(
      onTap: () {
        if (c.value.isPlaying) {
          c.pause();
        } else {
          c.play();
        }
        setState(() {});
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 220,
          height: 280,
          child: Stack(
            alignment: Alignment.center,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: c.value.size.width,
                  height: c.value.size.height,
                  child: VideoPlayer(c),
                ),
              ),
              if (!c.value.isPlaying)
                const Icon(Icons.play_circle_fill, color: Colors.white70, size: 48),
            ],
          ),
        ),
      ),
    );
  }
}
