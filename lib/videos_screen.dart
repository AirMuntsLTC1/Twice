// ignore_for_file: use_build_context_synchronously
//
// Twice "Videos" tab — Facebook Reels style.
// This file is a `part` of lib/main.dart so it can reuse the app's private
// helpers (_UserAvatar, _timeAgo, _openUserProfile, SocialPost, ...).
part of 'main.dart';

// ---------------------------------------------------------------------------
// Shared player settings (kept while the app is open)
// ---------------------------------------------------------------------------
final ValueNotifier<bool> _videoMuted = ValueNotifier<bool>(false);
final ValueNotifier<double> _videoSpeed = ValueNotifier<double>(1.0);
final ValueNotifier<bool> _videoAutoNext = ValueNotifier<bool>(false);

const Color _reelHeart = Color(0xFFFF3040);
const Color _fbGrey = Color(0xFF262626);
const List<Shadow> _reelShadow = <Shadow>[
  Shadow(color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 1)),
];

void _videoSnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------
class _VideoFeedData {
  static SupabaseClient get _db => Supabase.instance.client;

  // post_media!inner + the eq() below = only posts that contain a video.
  static const String _columns =
      'id,user_id,caption,visibility,comments_enabled,created_at,'
      'profiles!posts_user_id_fkey(id,username,display_name,avatar_url),'
      'post_media!inner(id,media_url,thumbnail_url,media_type,position),'
      'post_likes(user_id),saved_posts(user_id),comments(count)';

  static bool _isPath(String v) =>
      v.isNotEmpty &&
      v != 'pending' &&
      !v.startsWith('http://') &&
      !v.startsWith('https://');

  static Future<Map<String, String>> _sign(Set<String> paths) async {
    final result = <String, String>{};
    final list = paths.where((p) => p.isNotEmpty).toList();
    for (var i = 0; i < list.length; i += 100) {
      final chunk = list.sublist(i, min(i + 100, list.length));
      try {
        final signed = await _db.storage
            .from('post-media')
            // ignore: deprecated_member_use
            .createSignedUrls(chunk, 3600)
            .timeout(const Duration(seconds: 15));
        for (final item in signed) {
          final url = item.signedUrl;
          if (url.contains('token=')) result[item.path.toString()] = url;
        }
      } catch (e) {
        debugPrint('Videos: signing failed: $e');
      }
    }
    return result;
  }

  static Future<List<Map<String, dynamic>>> page({
    required int offset,
    int limit = 10,
  }) async {
    final rows = await _db
        .from('posts')
        .select(_columns)
        .eq('post_media.media_type', 'video')
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1)
        .timeout(const Duration(seconds: 25));

    final posts = (rows as List)
        .map((raw) => Map<String, dynamic>.from(raw as Map))
        .toList();

    final needed = <String>{};
    for (final post in posts) {
      final author = post['profiles'];
      if (author is Map) {
        final path = (author['avatar_url'] ?? '').toString().trim();
        if (_isPath(path)) needed.add(path);
      }
      for (final media in (post['post_media'] as List? ?? const [])) {
        if (media is! Map) continue;
        for (final key in const ['media_url', 'thumbnail_url']) {
          final path = (media[key] ?? '').toString().trim();
          if (_isPath(path)) needed.add(path);
        }
      }
    }
    final urls = await _sign(needed);
    String resolve(String path) {
      if (path.isEmpty) return '';
      if (!_isPath(path)) return path;
      return urls[path] ?? '';
    }

    for (final post in posts) {
      final authorRaw = post['profiles'];
      if (authorRaw is Map) {
        final author = Map<String, dynamic>.from(authorRaw);
        final path = (author['avatar_url'] ?? '').toString().trim();
        author['avatar_object_path'] = _isPath(path) ? path : '';
        author['avatar_url'] = resolve(path);
        post['profiles'] = author;
      }
      final media =
          (post['post_media'] as List? ?? const [])
              .whereType<Map>()
              .map((raw) => Map<String, dynamic>.from(raw))
              .where(
                (m) =>
                    (m['media_type'] ?? '').toString().toLowerCase() == 'video',
              )
              .toList()
            ..sort(
              (a, b) => (int.tryParse('${a['position']}') ?? 0).compareTo(
                int.tryParse('${b['position']}') ?? 0,
              ),
            );
      post['media_resolved'] = media.map((item) {
        item['resolved_url'] = resolve(
          (item['media_url'] ?? '').toString().trim(),
        );
        item['resolved_thumbnail_url'] = resolve(
          (item['thumbnail_url'] ?? '').toString().trim(),
        );
        return item;
      }).toList();
    }
    return posts
        .where((p) => (p['media_resolved'] as List).isNotEmpty)
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Videos tab (vertical pager)
// ---------------------------------------------------------------------------
class VideosPage extends StatefulWidget {
  const VideosPage({
    super.key,
    required this.active,
    required this.profile,
    required this.onCreate,
  });

  final bool active;
  final Map<String, dynamic> profile;
  final VoidCallback onCreate;

  @override
  State<VideosPage> createState() => _VideosPageState();
}

class _VideosPageState extends State<VideosPage> with WidgetsBindingObserver {
  static const int _pageSize = 10;

  final PageController _pager = PageController();
  final List<SocialPost> _posts = <SocialPost>[];
  bool _started = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _appResumed = true;
  String? _error;
  int _index = 0;

  // --- sponsored pages -----------------------------------------------------
  // Slots whose ad could not be loaded are left out of the pager, so the user
  // never lands on an empty black page.
  final Set<int> _deadAdSlots = <int>{};
  final Set<int> _prefetchingAds = <int>{};
  List<FeedEntry<SocialPost>> _entries = <FeedEntry<SocialPost>>[];
  bool _adsPrimed = false;

  /// Loads the ads that are 1-3 pages ahead, long before the user gets there.
  void _prefetchAdsAhead(int page) {
    if (!widget.active) return;
    final entries = _entries;
    for (var i = page + 1; i <= page + 3 && i < entries.length; i++) {
      final entry = entries[i];
      if (!entry.isAd) continue;
      final slot = entry.adSlot!;
      if (_deadAdSlots.contains(slot) || !_prefetchingAds.add(slot)) continue;
      TwiceAds.prefetch(AdPlacement.videos, slot).then((ok) {
        _prefetchingAds.remove(slot);
        if (!ok) _skipDeadAd(slot);
      });
    }
  }

  /// No ad for [slot]: drop its page. Pages behind the user are never touched,
  /// so the video on screen can't change under their finger.
  void _skipDeadAd(int slot) {
    if (!mounted || _deadAdSlots.contains(slot)) return;
    final adPage = _entries.indexWhere((e) => e.isAd && e.adSlot == slot);
    final current = _pager.hasClients ? (_pager.page ?? 0).round() : 0;
    if (adPage < 0 || adPage < current) return;
    setState(() => _deadAdSlots.add(slot));
    if (adPage == current) {
      // The ad page vanished and the next video now sits at this index.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || current >= _entries.length) return;
        if (_entries[current].isAd) return;
        final postIndex =
            _entries.take(current + 1).where((e) => !e.isAd).length - 1;
        _onPage(postIndex);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureStarted();
      });
    }
  }

  @override
  void didUpdateWidget(covariant VideosPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _ensureStarted();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final resumed = state == AppLifecycleState.resumed;
    if (resumed != _appResumed) setState(() => _appResumed = resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pager.dispose();
    super.dispose();
  }

  void _ensureStarted() {
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _VideoFeedData.page(offset: 0, limit: _pageSize);
      if (!mounted) return;
      if (_pager.hasClients) _pager.jumpToPage(0);
      setState(() {
        _posts
          ..clear()
          ..addAll(rows.map(SocialPost.new));
        _adsPrimed = false;
        _index = 0;
        _hasMore = rows.length >= _pageSize;
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    _loadingMore = true;
    try {
      final rows = await _VideoFeedData.page(
        offset: _posts.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      final known = _posts.map((p) => p.id).toSet();
      setState(() {
        for (final row in rows) {
          final post = SocialPost(row);
          if (known.add(post.id)) _posts.add(post);
        }
        _hasMore = rows.length >= _pageSize;
      });
    } catch (e) {
      debugPrint('Videos: load more failed: $e');
    } finally {
      _loadingMore = false;
    }
  }

  void _onPage(int i) {
    setState(() => _index = i);
    if (i >= _posts.length - 3) _loadMore();
  }

  bool _next() {
    if (!_pager.hasClients || _index >= _posts.length - 1) return false;
    _pager.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  void _openSearch() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Search')),
          body: const SearchPage(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final Widget body;
    if (_loading && _posts.isEmpty) {
      body = const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    } else if (_error != null && _posts.isEmpty) {
      body = _VideosMessage(
        icon: Icons.wifi_off_rounded,
        title: 'Couldn’t load videos',
        subtitle: _error!,
        actionLabel: 'Try again',
        onAction: _load,
      );
    } else if (_posts.isEmpty) {
      body = _VideosMessage(
        icon: Icons.video_library_outlined,
        title: 'No videos yet',
        subtitle: 'Videos that people post on Twice will show up here.',
        actionLabel: 'Create a video',
        onAction: widget.onCreate,
      );
    } else {
      final entries = interleaveAds<SocialPost>(
        _posts,
        interval: TwiceAdConfig.videoInterval,
        maxAds: TwiceAdConfig.maxAdSlots,
        skipSlots: _deadAdSlots,
      );
      _entries = entries;
      if (!_adsPrimed) {
        _adsPrimed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _prefetchAdsAhead(0);
        });
      }
      body = PageView.builder(
        scrollDirection: Axis.vertical,
        controller: _pager,
        itemCount: entries.length,
        onPageChanged: (page) {
          if (page >= entries.length) return;
          final entry = entries[page];
          _prefetchAdsAhead(page);
          if (entry.isAd) {
            setState(() => _index = -1);
            return;
          }
          final postIndex = entries.take(page + 1).where((e) => !e.isAd).length - 1;
          _onPage(postIndex);
        },
        itemBuilder: (context, page) {
          final entry = entries[page];
          if (entry.isAd) {
            // Full-page sponsored page. No nested scroll view: the pager owns
            // every vertical drag (ScrollThrough forwards drags that start on
            // the native ad), and "Next video" is a guaranteed way out.
            return FeedNativeAdCard(
              key: ValueKey<String>('video-ad-${entry.adSlot}'),
              placement: AdPlacement.videos,
              slot: entry.adSlot!,
              fullPage: true,
              active: widget.active,
              topInset: top + 52,
              onUnavailable: () => _skipDeadAd(entry.adSlot!),
              onContinue: _next,
            );
          }
          final post = entry.item!;
          final postIndex = entries.take(page + 1).where((e) => !e.isAd).length - 1;
          return _VideoReel(
            key: ValueKey<String>(post.id),
            post: post,
            myProfile: widget.profile,
            topInset: top,
            playing: widget.active && _appResumed && postIndex == _index,
            preload: postIndex == _index ||
                (widget.active && (postIndex - _index).abs() <= 1),
            onNext: _next,
          );
        },
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(child: body),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(16, top + 6, 6, 14),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x99000000), Color(0x00000000)],
                  ),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Videos',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        shadows: _reelShadow,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Create',
                      onPressed: widget.onCreate,
                      icon: const Icon(
                        Icons.add_circle_outline_rounded,
                        color: Colors.white,
                        shadows: _reelShadow,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Search',
                      onPressed: _openSearch,
                      icon: const Icon(
                        Icons.search_rounded,
                        color: Colors.white,
                        shadows: _reelShadow,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Video settings',
                      onPressed: () =>
                          _showVideoSettings(context, onRefresh: _load),
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        color: Colors.white,
                        shadows: _reelShadow,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideosMessage extends StatelessWidget {
  const _VideosMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 56),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: onAction,
            style: FilledButton.styleFrom(backgroundColor: violet),
            child: Text(actionLabel),
          ),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Settings sheet (speed, auto-scroll, sound)
// ---------------------------------------------------------------------------
Future<void> _showVideoSettings(
  BuildContext context, {
  VoidCallback? onRefresh,
}) {
  const speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  String label(double s) => s == s.roundToDouble() ? '${s.toInt()}x' : '${s}x';
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: igSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Video settings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 14),
            const Text(
              'Playback speed',
              style: TextStyle(fontWeight: FontWeight.w700, color: muted),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<double>(
              valueListenable: _videoSpeed,
              builder: (context, current, child) => Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final s in speeds)
                    ChoiceChip(
                      label: Text(label(s)),
                      selected: current == s,
                      selectedColor: const Color(0xFF363636),
                      onSelected: (_) => _videoSpeed.value = s,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            ValueListenableBuilder<bool>(
              valueListenable: _videoMuted,
              builder: (context, muted, child) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sound on'),
                value: !muted,
                onChanged: (on) => _videoMuted.value = !on,
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _videoAutoNext,
              builder: (context, auto, child) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-scroll to next video'),
                subtitle: const Text('Move on when a video finishes'),
                value: auto,
                onChanged: (v) => _videoAutoNext.value = v,
              ),
            ),
            if (onRefresh != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('Refresh videos'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onRefresh();
                },
              ),
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// One reel (full page)
// ---------------------------------------------------------------------------
class _Burst {
  _Burst(this.id, this.pos);
  final int id;
  final Offset pos;
}

class _VideoReel extends StatefulWidget {
  const _VideoReel({
    super.key,
    required this.post,
    required this.myProfile,
    required this.topInset,
    required this.playing,
    required this.preload,
    required this.onNext,
  });

  final SocialPost post;
  final Map<String, dynamic> myProfile;
  final double topInset;
  final bool playing;
  final bool preload;
  final bool Function() onNext;

  @override
  State<_VideoReel> createState() => _VideoReelState();
}

class _VideoReelState extends State<_VideoReel> {
  VideoPlayerController? _c;
  String _source = '';
  bool _initializing = false;
  bool _failed = false;
  bool _hasFrame = false;
  bool _userPaused = false;
  bool _routePaused = false;
  bool _boost = false;
  bool _advanced = false;
  bool _likePop = false;
  bool _showPauseIcon = false;
  double? _scrubValue;
  Timer? _iconTimer;
  Offset _tapPos = Offset.zero;
  int _burstSeq = 0;
  final List<_Burst> _bursts = <_Burst>[];

  Map<String, dynamic> get _video =>
      widget.post.media.isEmpty ? <String, dynamic>{} : widget.post.media.first;
  String? _urlOverride; // fresh signed URL after a refresh
  String get _url =>
      _urlOverride ?? (_video['resolved_url'] ?? '').toString().trim();
  String get _thumb =>
      (_video['resolved_thumbnail_url'] ?? '').toString().trim();
  String get _authorId =>
      (widget.post.data['user_id'] ?? widget.post.author['id'] ?? '')
          .toString();
  String? get _myId => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _videoMuted.addListener(_applyVolume);
    _videoSpeed.addListener(_applySpeed);
    _videoAutoNext.addListener(_applyLoop);
    if (widget.preload) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureController();
      });
    }
  }

  @override
  void didUpdateWidget(covariant _VideoReel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing && !widget.playing) _userPaused = false;
    if (widget.preload && _c == null && !_failed) {
      _ensureController();
    } else if (!widget.preload && _c != null) {
      _release();
    }
    _sync();
  }

  @override
  void dispose() {
    _videoMuted.removeListener(_applyVolume);
    _videoSpeed.removeListener(_applySpeed);
    _videoAutoNext.removeListener(_applyLoop);
    _iconTimer?.cancel();
    final c = _c;
    _c = null;
    c?.removeListener(_onTick);
    c?.dispose();
    super.dispose();
  }

  // ---- player ------------------------------------------------------------
  Future<void> _ensureController({bool allowRefresh = true}) async {
    if (_c != null || _initializing) return;
    if (_url.isEmpty) {
      if (allowRefresh && await _refreshUrl()) return;
      if (mounted) setState(() => _failed = true);
      return;
    }
    _initializing = true;
    if (mounted) setState(() {});

    var source = _url;
    if (source.startsWith('http')) {
      final local = await TwiceMedia.cachedFileUri(source);
      if (local != null) source = local;
    }
    if (!mounted) return;

    final controller = source.startsWith('file://')
        ? VideoPlayerController.file(File.fromUri(Uri.parse(source)))
        : VideoPlayerController.networkUrl(Uri.parse(source));
    _c = controller;
    _source = source;
    controller.addListener(_onTick);
    try {
      await controller.initialize();
      await controller.setLooping(!_videoAutoNext.value);
      await controller.setVolume(_videoMuted.value ? 0 : 1);
      await controller.setPlaybackSpeed(_videoSpeed.value);
      if (!mounted || !identical(_c, controller)) {
        controller.removeListener(_onTick);
        await controller.dispose();
        return;
      }
      _initializing = false;
      setState(() {});
      _sync();
    } catch (_) {
      controller.removeListener(_onTick);
      await controller.dispose();
      if (identical(_c, controller)) _c = null;
      _initializing = false;
      if (allowRefresh && await _refreshUrl()) return;
      if (mounted) setState(() => _failed = true);
    } finally {
      _initializing = false;
    }
  }

  Future<bool> _refreshUrl() async {
    final path = (_video['media_url'] ?? '').toString().trim();
    if (path.isEmpty || path.startsWith('http')) return false;
    try {
      final fresh = await SocialRepository.instance.refreshMediaUrl(
        path,
        bucket: 'post-media',
      );
      if (fresh == null || fresh.isEmpty || !mounted) return false;
      _urlOverride = fresh;
      setState(() => _failed = false);
      await _ensureController(allowRefresh: false);
      return _c != null && _c!.value.isInitialized;
    } catch (_) {
      return false;
    }
  }

  void _release() {
    final c = _c;
    if (c == null) return;
    _c = null;
    _hasFrame = false;
    c.removeListener(_onTick);
    c.pause();
    c.dispose();
    if (mounted) setState(() {});
  }

  void _onTick() {
    final c = _c;
    if (!mounted || c == null) return;
    final v = c.value;
    if (!_hasFrame && v.isInitialized && v.position > Duration.zero) {
      setState(() => _hasFrame = true);
    }
    if (_videoAutoNext.value && v.isInitialized && v.duration > Duration.zero) {
      final nearEnd =
          v.position >= v.duration - const Duration(milliseconds: 250);
      if (nearEnd && !_advanced && widget.playing) {
        _advanced = true;
        if (!widget.onNext()) {
          c.seekTo(Duration.zero);
          c.play();
        }
      } else if (!nearEnd &&
          v.position < v.duration - const Duration(seconds: 1)) {
        _advanced = false;
      }
    }
  }

  void _sync() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final shouldPlay = widget.playing && !_userPaused && !_routePaused;
    if (shouldPlay) {
      if (!c.value.isPlaying) {
        c.play();
        if (_source.startsWith('http')) {
          unawaited(TwiceMedia.cacheVideo(_source));
        }
      }
    } else if (c.value.isPlaying) {
      c.pause();
    }
  }

  void _applyVolume() => _c?.setVolume(_videoMuted.value ? 0 : 1);
  void _applySpeed() {
    if (!_boost) _c?.setPlaybackSpeed(_videoSpeed.value);
  }

  void _applyLoop() {
    _advanced = false;
    _c?.setLooping(!_videoAutoNext.value);
  }

  // ---- gestures ----------------------------------------------------------
  void _togglePause() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    setState(() {
      _userPaused = !_userPaused;
      _showPauseIcon = true;
    });
    _sync();
    _iconTimer?.cancel();
    _iconTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showPauseIcon = false);
    });
  }

  void _doubleTapLike() {
    HapticFeedback.lightImpact();
    final id = ++_burstSeq;
    setState(() => _bursts.add(_Burst(id, _tapPos)));
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _bursts.removeWhere((b) => b.id == id));
    });
    _setLiked(true);
  }

  void _startBoost() {
    final c = _c;
    if (c == null || !c.value.isInitialized || _userPaused) return;
    HapticFeedback.selectionClick();
    setState(() => _boost = true);
    c.setPlaybackSpeed(2.0);
  }

  void _endBoost() {
    if (!_boost) return;
    setState(() => _boost = false);
    _c?.setPlaybackSpeed(_videoSpeed.value);
  }

  void _scrubStart(double fraction) => setState(() => _scrubValue = fraction);
  void _scrubUpdate(double fraction) {
    if (_scrubValue != null) setState(() => _scrubValue = fraction);
  }

  void _scrubEnd() {
    final value = _scrubValue;
    final c = _c;
    if (value != null && c != null && c.value.isInitialized) {
      c.seekTo(
        Duration(
          milliseconds: (c.value.duration.inMilliseconds * value).round(),
        ),
      );
    }
    if (mounted) setState(() => _scrubValue = null);
  }

  // ---- actions -----------------------------------------------------------
  Future<void> _setLiked(bool like) async {
    final post = widget.post;
    final uid = _myId;
    if (uid == null || post.liked == like) return;
    final wasLiked = post.liked;
    setState(() {
      final rows = List<Map<String, dynamic>>.from(
        post.data['post_likes'] as List? ?? const [],
      );
      if (wasLiked) {
        rows.removeWhere((e) => e['user_id'] == uid);
      } else {
        rows.add(<String, dynamic>{'user_id': uid});
      }
      post.data['post_likes'] = rows;
      _likePop = true;
    });
    Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _likePop = false);
    });
    try {
      await SocialRepository.instance.toggleLike(post.id, wasLiked);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final rows = List<Map<String, dynamic>>.from(
          post.data['post_likes'] as List? ?? const [],
        );
        rows.removeWhere((row) => row['user_id'] == uid);
        if (wasLiked) rows.add(<String, dynamic>{'user_id': uid});
        post.data['post_likes'] = rows;
      });
      _videoSnack(context, 'Like could not sync: $e');
    }
  }

  Future<void> _toggleSave() async {
    final post = widget.post;
    final uid = _myId;
    if (uid == null) return;
    final was = post.saved;
    setState(() {
      post.data['saved_posts'] = was
          ? <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[
              <String, dynamic>{'user_id': uid},
            ];
    });
    try {
      await SocialRepository.instance.toggleSaved(post.id, was);
      if (mounted) {
        _videoSnack(context, was ? 'Removed from saved' : 'Video saved');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        post.data['saved_posts'] = was
            ? <Map<String, dynamic>>[
                <String, dynamic>{'user_id': uid},
              ]
            : <Map<String, dynamic>>[];
      });
      _videoSnack(context, 'Could not update saved: $e');
    }
  }

  Future<void> _share() async {
    final post = widget.post;
    String thumbUrl = '';
    if (post.media.isNotEmpty) {
      thumbUrl = (post.media.first['resolved_url'] ?? '').toString();
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ShareSheet(
        postId: post.id,
        postCaption: post.caption,
        postThumbnailUrl: thumbUrl,
      ),
    );
  }

  Future<void> _openComments({bool focus = false}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _VideoCommentsSheet(
        post: widget.post,
        myProfile: widget.myProfile,
        autofocus: focus,
        onCountChanged: (n) {
          if (!mounted) return;
          setState(() {
            widget.post.data['comments'] = <Map<String, dynamic>>[
              <String, dynamic>{'count': n},
            ];
          });
        },
      ),
    );
  }

  Future<void> _openProfile() async {
    if (_authorId.isEmpty) return;
    setState(() => _routePaused = true);
    _sync();
    await _openUserProfile(
      context,
      userId: _authorId,
      profile: Map<String, dynamic>.from(widget.post.author),
    );
    if (!mounted) return;
    setState(() => _routePaused = false);
    _sync();
  }

  void _openMore() {
    final post = widget.post;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: igSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(height: 6),
            ListTile(
              leading: Icon(
                post.saved
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
              ),
              title: Text(post.saved ? 'Remove from saved' : 'Save video'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _toggleSave();
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('Share'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _share();
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_outline_rounded),
              title: Text('View ${post.name}’s profile'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openProfile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.speed_rounded),
              title: const Text('Playback speed & settings'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showVideoSettings(context);
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  // ---- UI ----------------------------------------------------------------
  Widget _videoLayer() {
    final c = _c;
    final poster = TwiceVideoPoster(
      videoUrl: _url,
      thumbnailUrl: _thumb,
      imageProviderFor: _twiceImageProvider,
      fit: BoxFit.contain,
      showPlayIcon: false,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!(_hasFrame && c != null)) poster,
        if (c != null && c.value.isInitialized)
          AnimatedOpacity(
            opacity: _hasFrame ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Builder(
              builder: (context) {
                final size = c.value.size;
                final ratio = size.height <= 0 ? 1.0 : size.width / size.height;
                return FittedBox(
                  fit: ratio < 0.85 ? BoxFit.cover : BoxFit.contain,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: VideoPlayer(c),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _railButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white,
    bool pop = false,
    Widget? customIcon,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 58,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: pop ? 1.3 : 1,
              duration: const Duration(milliseconds: 150),
              child:
                  customIcon ??
                  Icon(icon, color: color, size: 31, shadows: _reelShadow),
            ),
            if (label.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  shadows: _reelShadow,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _rail() {
    final post = widget.post;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _railButton(
          icon: post.liked
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          color: post.liked ? _reelHeart : Colors.white,
          label: _compactCount(post.likes),
          pop: _likePop,
          onTap: () => _setLiked(!post.liked),
        ),
        _railButton(
          icon: Icons.mode_comment_outlined,
          customIcon: IgComment(size: 31, color: Colors.white),
          label: post.data['comments_enabled'] == false
              ? ''
              : _compactCount(post.commentCount),
          onTap: _openComments,
        ),
        _railButton(
          icon: Icons.ios_share_rounded,
          customIcon: IgShare(size: 31, color: Colors.white),
          label: 'Share',
          onTap: _share,
        ),
        _railButton(
          icon: post.saved
              ? Icons.bookmark_rounded
              : Icons.bookmark_border_rounded,
          label: post.saved ? 'Saved' : 'Save',
          onTap: _toggleSave,
        ),
        _railButton(
          icon: Icons.more_horiz_rounded,
          label: '',
          onTap: _openMore,
        ),
      ],
    );
  }

  Widget _info() {
    final post = widget.post;
    final visibility = (post.data['visibility'] ?? 'public').toString();
    final visIcon = visibility == 'public'
        ? Icons.public_rounded
        : visibility == 'followers'
        ? Icons.group_rounded
        : Icons.lock_rounded;
    final time = _timeAgo(post.data['created_at']);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            GestureDetector(
              onTap: _openProfile,
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: _UserAvatar(
                  url: post.avatarUrl ?? '',
                  name: post.name,
                  size: 38,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openProfile,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    VerifiedName(
                      userId: (post.author['id'] ?? '').toString(),
                      name: post.name,
                      username: post.username,
                      size: 15,
                      child: Text(
                        post.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          shadows: _reelShadow,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            post.handle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              shadows: _reelShadow,
                            ),
                          ),
                        ),
                        if (time.isNotEmpty)
                          Text(
                            '  ·  $time  ·  ',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              shadows: _reelShadow,
                            ),
                          ),
                        Icon(visIcon, size: 12, color: Colors.white70),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_authorId.isNotEmpty && _authorId != _myId)
              _ReelFollowButton(profileId: _authorId),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Icon(Icons.music_note_rounded, size: 15, color: Colors.white),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'Original audio · ${post.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  shadows: _reelShadow,
                ),
              ),
            ),
          ],
        ),
        if (post.caption.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          _ReelCaption(text: post.caption.trim()),
        ],
      ],
    );
  }

  Widget _commentBand() {
    final me = widget.myProfile;
    final myName = (me['display_name'] ?? me['username'] ?? '').toString();
    final disabled = widget.post.data['comments_enabled'] == false;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: disabled ? null : () => _openComments(focus: true),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white54),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  disabled
                      ? 'Comments are turned off'
                      : (myName.isEmpty
                            ? 'Add a comment…'
                            : 'Add a comment as $myName'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                ),
              ),
              if (!disabled) ...const [
                Icon(
                  Icons.alternate_email_rounded,
                  size: 20,
                  color: Colors.white70,
                ),
                SizedBox(width: 12),
                Icon(
                  Icons.sentiment_satisfied_alt_rounded,
                  size: 21,
                  color: Colors.white70,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final buffering =
        _initializing ||
        (c != null && c.value.isInitialized && c.value.isBuffering);
    final scrub = _scrubValue;

    final stage = LayoutBuilder(
      builder: (context, box) => Stack(
        fit: StackFit.expand,
        children: [
          _videoLayer(),
          // Gesture layer: tap = play/pause, double tap = heart,
          // long press = 2x, horizontal drag = seek.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePause,
              onDoubleTapDown: (d) => _tapPos = d.localPosition,
              onDoubleTap: _doubleTapLike,
              onLongPressStart: (_) => _startBoost(),
              onLongPressEnd: (_) => _endBoost(),
              onLongPressCancel: _endBoost,
              onHorizontalDragStart: (d) {
                final cc = _c;
                if (cc == null || !cc.value.isInitialized) return;
                final total = cc.value.duration.inMilliseconds;
                _scrubStart(
                  total <= 0
                      ? 0
                      : (cc.value.position.inMilliseconds / total).clamp(
                          0.0,
                          1.0,
                        ),
                );
              },
              onHorizontalDragUpdate: (d) {
                final current = _scrubValue;
                if (current == null) return;
                _scrubUpdate(
                  (current + d.delta.dx / max(box.maxWidth * 0.9, 1)).clamp(
                    0.0,
                    1.0,
                  ),
                );
              },
              onHorizontalDragEnd: (_) => _scrubEnd(),
              onHorizontalDragCancel: _scrubEnd,
              child: const SizedBox.expand(),
            ),
          ),
          const IgnorePointer(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 280,
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xB3000000)],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (buffering)
            const IgnorePointer(
              child: Center(
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          if (_failed)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Colors.white70,
                    size: 44,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Couldn’t play this video',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () {
                      setState(() => _failed = false);
                      _ensureController();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                    ),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: _showPauseIcon ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Color(0x66000000),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _userPaused
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
              ),
            ),
          ),
          if (_boost)
            Positioned(
              top: widget.topInset + 62,
              left: 0,
              right: 0,
              child: const IgnorePointer(child: Center(child: _SpeedChip())),
            ),
          if (scrub != null && c != null && c.value.isInitialized)
            Positioned(
              left: 0,
              right: 0,
              bottom: 150,
              child: IgnorePointer(
                child: Center(
                  child: Text(
                    '${_formatClock((c.value.duration.inSeconds * scrub).round())}'
                    '  /  ${_formatClock(c.value.duration.inSeconds)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      shadows: _reelShadow,
                    ),
                  ),
                ),
              ),
            ),
          // Mute toggle
          Positioned(
            right: 12,
            top: widget.topInset + 62,
            child: ValueListenableBuilder<bool>(
              valueListenable: _videoMuted,
              builder: (context, muted, child) => GestureDetector(
                onTap: () => _videoMuted.value = !muted,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    color: Color(0x66000000),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
          for (final b in _bursts)
            Positioned(
              key: ValueKey<int>(b.id),
              left: b.pos.dx - 48,
              top: b.pos.dy - 48,
              child: IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 750),
                  builder: (context, t, child) {
                    final scale = t < 0.3
                        ? 0.4 + (t / 0.3) * 0.9
                        : 1.3 - (t - 0.3) * 0.3;
                    final opacity = t < 0.6 ? 1.0 : (1 - (t - 0.6) / 0.4);
                    return Opacity(
                      opacity: opacity.clamp(0.0, 1.0),
                      child: Transform.scale(scale: scale, child: child),
                    );
                  },
                  child: const Icon(
                    Icons.favorite_rounded,
                    size: 96,
                    color: _reelHeart,
                  ),
                ),
              ),
            ),
          Positioned(left: 12, right: 76, bottom: 30, child: _info()),
          Positioned(right: 6, bottom: 24, child: _rail()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _ReelProgress(
              controller: c,
              scrubValue: scrub,
              onScrubStart: _scrubStart,
              onScrubUpdate: _scrubUpdate,
              onScrubEnd: _scrubEnd,
            ),
          ),
        ],
      ),
    );

    return ColoredBox(
      color: Colors.black,
      child: Column(
        children: [
          Expanded(child: stage),
          _commentBand(),
        ],
      ),
    );
  }
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
    decoration: BoxDecoration(
      color: const Color(0x99000000),
      borderRadius: BorderRadius.circular(20),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.fast_forward_rounded, color: Colors.white, size: 20),
        SizedBox(width: 6),
        Text(
          '2x speed',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 14,
          ),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Progress / seek bar
// ---------------------------------------------------------------------------
class _ReelProgress extends StatelessWidget {
  const _ReelProgress({
    required this.controller,
    required this.scrubValue,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
  });

  final VideoPlayerController? controller;
  final double? scrubValue;
  final ValueChanged<double> onScrubStart;
  final ValueChanged<double> onScrubUpdate;
  final VoidCallback onScrubEnd;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        double frac(double dx) =>
            width <= 0 ? 0.0 : (dx / width).clamp(0.0, 1.0);

        Widget track(double f) {
          final scrubbing = scrubValue != null;
          final h = scrubbing ? 5.0 : 2.5;
          return SizedBox(
            height: h,
            width: width,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(color: Colors.white24),
                FractionallySizedBox(
                  widthFactor: f.clamp(0.0, 1.0),
                  alignment: Alignment.centerLeft,
                  child: Container(color: Colors.white),
                ),
                if (scrubbing)
                  Positioned(
                    left: (width * f - 6).clamp(0.0, max(width - 12, 0.0)),
                    top: -3.5,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            onScrubStart(frac(d.localPosition.dx));
            onScrubEnd();
          },
          onHorizontalDragStart: (d) => onScrubStart(frac(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) =>
              onScrubUpdate(frac(d.localPosition.dx)),
          onHorizontalDragEnd: (_) => onScrubEnd(),
          onHorizontalDragCancel: onScrubEnd,
          child: SizedBox(
            height: 22,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: c == null
                  ? track(0)
                  : ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: c,
                      builder: (context, value, child) {
                        final total = value.duration.inMilliseconds;
                        final played = total <= 0
                            ? 0.0
                            : (value.position.inMilliseconds / total).clamp(
                                0.0,
                                1.0,
                              );
                        return track(scrubValue ?? played);
                      },
                    ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Caption with "… more"
// ---------------------------------------------------------------------------
class _ReelCaption extends StatefulWidget {
  const _ReelCaption({required this.text});
  final String text;

  @override
  State<_ReelCaption> createState() => _ReelCaptionState();
}

class _ReelCaptionState extends State<_ReelCaption> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 14,
      height: 1.3,
      shadows: _reelShadow,
    );
    return LayoutBuilder(
      builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 2,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: box.maxWidth);
        final overflows = painter.didExceedMaxLines;
        if (_expanded) {
          return GestureDetector(
            onTap: () => setState(() => _expanded = false),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 170),
              child: SingleChildScrollView(
                child: Text(widget.text, style: style),
              ),
            ),
          );
        }
        return GestureDetector(
          onTap: overflows ? () => setState(() => _expanded = true) : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
              if (overflows)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    'more',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      shadows: _reelShadow,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Follow button (Facebook reel style: outlined white pill)
// ---------------------------------------------------------------------------
class _ReelFollowButton extends StatefulWidget {
  const _ReelFollowButton({required this.profileId});
  final String profileId;

  @override
  State<_ReelFollowButton> createState() => _ReelFollowButtonState();
}

class _ReelFollowButtonState extends State<_ReelFollowButton> {
  String _label = '';
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final label = await SocialRepository.instance.getFollowLabel(
        widget.profileId,
      );
      if (mounted) {
        setState(() {
          _label = label;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _label = '';
          _loading = false;
        });
      }
    }
  }

  Future<void> _tap() async {
    if (_busy || _label.isEmpty) return;
    final previous = _label;
    final repo = SocialRepository.instance;
    setState(() => _busy = true);
    try {
      if (previous == 'Following' ||
          previous == 'Connected' ||
          previous == 'Requested') {
        setState(() => _label = 'Follow');
        await repo.unfollow(widget.profileId);
      } else {
        final isPrivate = await repo.isPrivateAccount(widget.profileId);
        if (!mounted) return;
        setState(() => _label = isPrivate ? 'Requested' : 'Following');
        await repo.follow(widget.profileId, privateAccount: isPrivate);
      }
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _label = previous);
        _videoSnack(context, 'Could not update follow: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _label.isEmpty) return const SizedBox.shrink();
    final active = _label == 'Following' || _label == 'Connected';
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: SizedBox(
        height: 30,
        child: OutlinedButton(
          onPressed: _busy ? null : _tap,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white54,
            side: BorderSide(color: active ? Colors.white38 : Colors.white),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            _label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: active ? Colors.white70 : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Comments sheet: Facebook look, heart reactions, replies
// ---------------------------------------------------------------------------
class _VideoCommentsSheet extends StatefulWidget {
  const _VideoCommentsSheet({
    required this.post,
    required this.myProfile,
    required this.onCountChanged,
    this.autofocus = false,
  });

  final SocialPost post;
  final Map<String, dynamic> myProfile;
  final ValueChanged<int> onCountChanged;
  final bool autofocus;

  @override
  State<_VideoCommentsSheet> createState() => _VideoCommentsSheetState();
}

class _VideoCommentsSheetState extends State<_VideoCommentsSheet> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  final Map<String, int> _likeCounts = <String, int>{};
  final Set<String> _myLikes = <String>{};
  final Set<String> _expanded = <String>{};
  bool _loading = true;
  bool _newestFirst = false;
  bool _sending = false;
  String? _error;
  Map<String, dynamic>? _replyTo; // top-level comment being replied to
  String _replyName = '';
  Map<String, dynamic> _me = <String, dynamic>{};

  SupabaseClient get _db => Supabase.instance.client;
  String? get _uid => _db.auth.currentUser?.id;
  bool get _commentsOff => widget.post.data['comments_enabled'] == false;

  @override
  void initState() {
    super.initState();
    _me = Map<String, dynamic>.from(widget.myProfile);
    _loadMe();
    _load();
    if (widget.autofocus && !_commentsOff) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadMe() async {
    if ((_me['username'] ?? '').toString().isNotEmpty &&
        (_me['avatar_url'] ?? '').toString().isNotEmpty) {
      return;
    }
    try {
      final me = await SocialRepository.instance.commentAuthorProfile();
      if (mounted) setState(() => _me = me);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await SocialRepository.instance.comments(widget.post.id);
      final likeCounts = <String, int>{};
      final mine = <String>{};
      final ids = data.map((r) => r['id'].toString()).toList();
      for (var i = 0; i < ids.length; i += 50) {
        final chunk = ids.sublist(i, min(i + 50, ids.length));
        try {
          final likes = await _db
              .from('comment_likes')
              .select('comment_id,user_id')
              .inFilter('comment_id', chunk)
              .timeout(const Duration(seconds: 15));
          for (final raw in likes as List) {
            final row = raw as Map;
            final cid = row['comment_id'].toString();
            likeCounts[cid] = (likeCounts[cid] ?? 0) + 1;
            if (row['user_id'] == _uid) mine.add(cid);
          }
        } catch (e) {
          debugPrint('Videos: comment likes unavailable: $e');
        }
      }
      if (!mounted) return;
      setState(() {
        _rows
          ..clear()
          ..addAll(data);
        _likeCounts
          ..clear()
          ..addAll(likeCounts);
        _myLikes
          ..clear()
          ..addAll(mine);
        _loading = false;
      });
      widget.onCountChanged(_rows.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Map<String, dynamic> _profileOf(Map<String, dynamic> row) {
    final raw = row['profiles'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return Map<String, dynamic>.from(raw.first as Map);
    }
    return <String, dynamic>{};
  }

  DateTime _dateOf(Map<String, dynamic> row) =>
      DateTime.tryParse('${row['created_at']}') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  int _likesOf(Map<String, dynamic> row) =>
      _likeCounts[row['id'].toString()] ?? 0;

  Future<void> _toggleLike(Map<String, dynamic> row) async {
    final uid = _uid;
    final id = row['id'].toString();
    if (uid == null || row['_pending'] == true) return;
    final liked = _myLikes.contains(id);
    HapticFeedback.selectionClick();
    setState(() {
      if (liked) {
        _myLikes.remove(id);
        _likeCounts[id] = max(0, (_likeCounts[id] ?? 1) - 1);
      } else {
        _myLikes.add(id);
        _likeCounts[id] = (_likeCounts[id] ?? 0) + 1;
      }
    });
    try {
      if (liked) {
        await _db
            .from('comment_likes')
            .delete()
            .eq('comment_id', id)
            .eq('user_id', uid);
      } else {
        await _db
            .from('comment_likes')
            .upsert(
              <String, dynamic>{'comment_id': id, 'user_id': uid},
              onConflict: 'comment_id,user_id',
              ignoreDuplicates: true,
            );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (liked) {
          _myLikes.add(id);
          _likeCounts[id] = (_likeCounts[id] ?? 0) + 1;
        } else {
          _myLikes.remove(id);
          _likeCounts[id] = max(0, (_likeCounts[id] ?? 1) - 1);
        }
      });
      _videoSnack(context, 'Heart could not sync: $e');
    }
  }

  void _startReply(Map<String, dynamic> row) {
    final parentId = row['parent_id']?.toString();
    final top = parentId == null
        ? row
        : _rows.firstWhere(
            (r) => r['id'].toString() == parentId,
            orElse: () => row,
          );
    final p = _profileOf(row);
    final name = (p['display_name'] ?? p['username'] ?? 'Twice user')
        .toString();
    setState(() {
      _replyTo = top;
      _replyName = name;
    });
    if (parentId != null) {
      final username = (p['username'] ?? '').toString();
      if (username.isNotEmpty) {
        _input.text = '@$username ';
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      }
    }
    _focus.requestFocus();
  }

  Future<void> _send(String text, CommentAttachment? attachment) async {
    if (_sending) return;
    final uid = _uid;
    if ((text.isEmpty && attachment == null) || uid == null) return;
    final parent = _replyTo;
    final parentId = parent?['id']?.toString();
    final id = _newTwiceUuid();
    if ((_me['username'] ?? '').toString().isEmpty) {
      try {
        _me = await SocialRepository.instance.commentAuthorProfile();
      } catch (_) {}
    }
    final me = _me;
    final optimistic = <String, dynamic>{
      'id': id,
      'post_id': widget.post.id,
      'user_id': uid,
      'parent_id': parentId,
      'body': text,
      'created_at': DateTime.now().toIso8601String(),
      'profiles': <String, dynamic>{
        'id': uid,
        'username': me['username'],
        'display_name': me['display_name'] ?? me['username'],
        'avatar_url': me['avatar_url'],
      },
      if (attachment != null && attachment.isPhoto)
        '_local_path': attachment.file!.path,
      if (attachment != null && !attachment.isPhoto) 'media_url': attachment.url,
      if (attachment != null) 'media_type': attachment.type,
      '_pending': true,
      '_fresh': true,
    };
    setState(() {
      _rows.add(optimistic);
      if (parentId != null) _expanded.add(parentId);
      _replyTo = null;
      _replyName = '';
      _sending = true;
    });
    _input.clear();
    FocusScope.of(context).unfocus();
    widget.onCountChanged(_rows.length);

    try {
      String? mediaUrl = attachment?.isPhoto == true ? null : attachment?.url;
      if (attachment != null && attachment.isPhoto) {
        mediaUrl = await SocialRepository.instance.uploadCommentPhoto(
          attachment.file!,
        );
      }
      final synced = await SocialRepository.instance.addComment(
        widget.post.id,
        text,
        commentId: id,
        parentId: parentId,
        mediaUrl: mediaUrl,
        mediaType: attachment?.type,
      );
      if (!mounted) return;
      setState(() {
        optimistic.remove('_pending');
        if (mediaUrl != null) optimistic['media_url'] = mediaUrl;
        if (!synced) optimistic['_queued'] = true;
      });
      if (!synced) {
        _videoSnack(context, 'Saved offline. It will sync when you reconnect.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        optimistic.remove('_pending');
        optimistic['_failed'] = true;
      });
      _videoSnack(context, 'Comment could not be sent: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final id = row['id'].toString();
    final removedIds = <String>{id};
    for (final r in _rows) {
      if (r['parent_id']?.toString() == id) removedIds.add(r['id'].toString());
    }
    final backup = _rows
        .where((r) => removedIds.contains(r['id'].toString()))
        .toList();
    setState(
      () => _rows.removeWhere((r) => removedIds.contains(r['id'].toString())),
    );
    widget.onCountChanged(_rows.length);
    try {
      await _db.from('comments').delete().eq('id', id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _rows.addAll(backup));
      widget.onCountChanged(_rows.length);
      _videoSnack(context, 'Could not delete comment: $e');
    }
  }

  void _commentMenu(Map<String, dynamic> row) {
    final mine = row['user_id']?.toString() == _uid;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: igSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(
                _myLikes.contains(row['id'].toString())
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: _reelHeart,
              ),
              title: Text(
                _myLikes.contains(row['id'].toString())
                    ? 'Remove heart'
                    : 'Heart',
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _toggleLike(row);
              },
            ),
            if (!_commentsOff)
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _startReply(row);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: '${row['body']}'));
                Navigator.of(sheetContext).pop();
              },
            ),
            if (mine)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red,
                ),
                title: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _delete(row);
                },
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Future<void> _openCommenter(Map<String, dynamic> row) async {
    final p = _profileOf(row);
    await _openUserProfile(
      context,
      userId: (p['id'] ?? row['user_id'] ?? '').toString(),
      profile: p,
    );
  }

  Widget _tile(Map<String, dynamic> row, {required bool isReply}) {
    final p = _profileOf(row);
    final id = row['id'].toString();
    final name = (p['display_name'] ?? p['username'] ?? 'Twice user')
        .toString();
    final avatar = (p['avatar_url'] ?? '').toString();
    final isAuthor =
        row['user_id']?.toString() == widget.post.data['user_id']?.toString();
    final liked = _myLikes.contains(id);
    final likes = _likesOf(row);
    final pending = row['_pending'] == true;
    final failed = row['_failed'] == true;
    final queued = row['_queued'] == true;
    final status = failed
        ? 'Not sent'
        : queued
        ? 'Waiting to sync'
        : pending
        ? 'Sending…'
        : _timeAgo(row['created_at']);

    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: isReply ? 46 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => _openCommenter(row),
            child: _UserAvatar(
              url: avatar,
              name: name,
              size: isReply ? 28 : 36,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onLongPress: () => _commentMenu(row),
                  onDoubleTap: () => _toggleLike(row),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
                    decoration: BoxDecoration(
                      color: _fbGrey,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: GestureDetector(
                                onTap: () => _openCommenter(row),
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                    color: ink,
                                  ),
                                ),
                              ),
                            ),
                            VerifiedBadge(
                              userId: (p['id'] ?? row['user_id'] ?? '')
                                  .toString(),
                              size: 14,
                              name: name,
                              username: (p['username'] ?? '').toString(),
                            ),
                            if (isAuthor) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF363636),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'Author',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: violet,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          '@${(p['username'] ?? 'user').toString().replaceFirst(RegExp(r'^@'), '')}',
                          style: const TextStyle(fontSize: 11.5, color: muted),
                        ),
                        const SizedBox(height: 3),
                        if ('${row['body']}'.trim().isNotEmpty)
                          Text(
                            '${row['body']}',
                            style: const TextStyle(
                              fontSize: 15,
                              height: 1.25,
                              color: ink,
                            ),
                          ),
                        if (CommentMediaView.hasMedia(row))
                          CommentMediaView(row: row, maxWidth: 200),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 5, 0, 0),
                  child: Row(
                    children: [
                      Text(
                        status,
                        style: TextStyle(
                          fontSize: 12,
                          color: failed ? Colors.red : muted,
                        ),
                      ),
                      if (!_commentsOff && !pending) ...[
                        const SizedBox(width: 16),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _startReply(row),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              'Reply',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: muted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Heart on the right, like Facebook Reels comments.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleLike(row),
            child: Padding(
              padding: const EdgeInsets.only(left: 8, top: 8, right: 2),
              child: SizedBox(
                width: 30,
                child: Column(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      transitionBuilder: (child, anim) =>
                          ScaleTransition(scale: anim, child: child),
                      child: Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        key: ValueKey<bool>(liked),
                        size: 20,
                        color: liked ? _reelHeart : muted,
                      ),
                    ),
                    if (likes > 0)
                      Text(
                        _compactCount(likes),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: liked ? _reelHeart : muted,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _thread() {
    final ids = _rows.map((r) => r['id'].toString()).toSet();
    final children = <String, List<Map<String, dynamic>>>{};
    final top = <Map<String, dynamic>>[];
    for (final r in _rows) {
      final pid = r['parent_id']?.toString();
      if (pid == null || pid.isEmpty || pid == 'null' || !ids.contains(pid)) {
        top.add(r);
      } else {
        children.putIfAbsent(pid, () => <Map<String, dynamic>>[]).add(r);
      }
    }
    top.sort((a, b) {
      final fa = a['_fresh'] == true, fb = b['_fresh'] == true;
      if (fa != fb) return fa ? -1 : 1;
      if (_newestFirst) return _dateOf(b).compareTo(_dateOf(a));
      final byLikes = _likesOf(b).compareTo(_likesOf(a));
      return byLikes != 0 ? byLikes : _dateOf(a).compareTo(_dateOf(b));
    });

    final widgets = <Widget>[];
    for (final r in top) {
      final id = r['id'].toString();
      widgets.add(_tile(r, isReply: false));
      final replies = (children[id] ?? <Map<String, dynamic>>[])
        ..sort((a, b) => _dateOf(a).compareTo(_dateOf(b)));
      if (replies.isEmpty) continue;
      if (_expanded.contains(id)) {
        for (final reply in replies) {
          widgets.add(_tile(reply, isReply: true));
        }
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 46, bottom: 12),
            child: GestureDetector(
              onTap: () => setState(() => _expanded.remove(id)),
              child: const Text(
                'Hide replies',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: muted,
                ),
              ),
            ),
          ),
        );
      } else {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 46, bottom: 12),
            child: GestureDetector(
              onTap: () => setState(() => _expanded.add(id)),
              child: Row(
                children: [
                  Container(width: 22, height: 1, color: Colors.black26),
                  const SizedBox(width: 8),
                  Text(
                    replies.length == 1
                        ? 'View 1 reply'
                        : 'View ${replies.length} replies',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }
    return widgets;
  }

  Widget _composer() {
    if (_commentsOff) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Comments are turned off for this video.',
          style: TextStyle(color: muted),
        ),
      );
    }
    final me = _me;
    final myName = (me['display_name'] ?? me['username'] ?? '').toString();
    return Container(
      decoration: const BoxDecoration(
        color: igSurface,
        border: Border(top: BorderSide(color: Color(0xFF363636), width: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyTo != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Replying to $_replyName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: muted),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _replyTo = null;
                        _replyName = '';
                      });
                      _input.clear();
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded, size: 18, color: muted),
                    ),
                  ),
                ],
              ),
            ),
          CommentInputBar(
            controller: _input,
            focusNode: _focus,
            sending: _sending,
            sendColor: violet,
            fillColor: _fbGrey,
            hintText: _replyTo == null
                ? (myName.isEmpty ? 'Add a comment…' : 'Comment as $myName…')
                : 'Reply to $_replyName…',
            leading: _UserAvatar(
              url: (me['avatar_url'] ?? '').toString(),
              name: myName,
              size: 34,
            ),
            onSubmit: _send,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final inset = media.viewInsets.bottom;
    final height = min(
      media.size.height * 0.76,
      media.size.height - inset - media.padding.top - 12,
    );
    final thread = _thread();
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: Container(
        height: max(height, 240),
        decoration: const BoxDecoration(
          color: igSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _rows.length == 1
                          ? '1 comment'
                          : '${_rows.length} comments',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  PopupMenuButton<bool>(
                    tooltip: 'Sort comments',
                    onSelected: (newest) =>
                        setState(() => _newestFirst = newest),
                    itemBuilder: (_) => const [
                      PopupMenuItem<bool>(
                        value: false,
                        child: Text('Most relevant'),
                      ),
                      PopupMenuItem<bool>(value: true, child: Text('Newest')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _newestFirst ? 'Newest' : 'Most relevant',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: muted,
                            ),
                          ),
                          const Icon(
                            Icons.arrow_drop_down_rounded,
                            color: muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Could not load comments'),
                            const SizedBox(height: 6),
                            Text(
                              _error!,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12,
                              ),
                            ),
                            TextButton(
                              onPressed: _load,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : thread.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.mode_comment_outlined,
                              size: 44,
                              color: muted,
                            ),
                            SizedBox(height: 10),
                            Text(
                              'No comments yet',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Be the first to comment.',
                              style: TextStyle(color: muted),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(14, 14, 10, 8),
                      children: thread,
                    ),
            ),
            _composer(),
          ],
        ),
      ),
    );
  }
}

