import 'dart:ffi' hide Size;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/social_repository.dart';

const ink = Color(0xFF171923);
const muted = Color(0xFF7B8191);
const violet = Color(0xFF7257F5);
const canvas = Color(0xFFF7F7FB);

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabasePublishableKey =
    String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

bool get supabaseConfigured =>
    supabaseUrl.startsWith('https://') &&
    supabasePublishableKey.isNotEmpty;

// True only after Supabase has initialized successfully. If configuration is
// missing or initialization fails, the app still starts and shows its setup
// screen instead of remaining on Android's Flutter splash screen.
bool supabaseReady = false;
String? supabaseStartupError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Never let a bad/missing Supabase configuration prevent Flutter from
  // drawing the first frame indefinitely.
  if (!supabaseConfigured) {
    final missing = <String>[
      if (!supabaseUrl.startsWith('https://')) 'SUPABASE_URL',
      if (supabasePublishableKey.isEmpty) 'SUPABASE_PUBLISHABLE_KEY',
    ];
    supabaseStartupError =
        'Missing or invalid build configuration: ${missing.join(', ')}. '
        'Check GitHub Repository secrets and rebuild the APK.';
  } else {
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabasePublishableKey,
      ).timeout(const Duration(seconds: 12));
      supabaseReady = true;
    } catch (error, stackTrace) {
      // Keep startup alive; the auth gate will show the configuration screen.
      debugPrint('Twice Supabase startup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      supabaseReady = false;
      final details = error
          .toString()
          .replaceAll(supabaseUrl, '[Supabase URL hidden]')
          .replaceAll(supabasePublishableKey, '[key hidden]');
      supabaseStartupError =
          'Supabase initialization failed (${error.runtimeType}): $details';
    }
  }


  runApp(const TwiceApp());
}

class NativeCore {
  NativeCore._() {
    try {
      final lib = DynamicLibrary.open('libtwice_native.so');
      _add = lib
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
            'twice_native_add',
          );
    } catch (_) {
      // Keeps Flutter tests and non-Android preview environments usable.
      _add = null;
    }
  }

  static final NativeCore instance = NativeCore._();

  late final int Function(int, int)? _add;

  int add(int a, int b) => _add?.call(a, b) ?? a + b;

  bool get isLoaded => _add != null;
}

class TwiceApp extends StatelessWidget {
  const TwiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Twice',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: canvas,
        colorScheme: ColorScheme.fromSeed(
          seedColor: violet,
          brightness: Brightness.light,
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: canvas,
          foregroundColor: ink,
          elevation: 0,
          centerTitle: false,
        ),
      ),
      home: const TwiceAuthGate(),
    );
  }
}


class TwiceAuthGate extends StatelessWidget {
  const TwiceAuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    if (!supabaseReady) {
      return TwiceSignInPage(
        configurationMissing: true,
        startupError: supabaseStartupError,
      );
    }

    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        if (session != null) return const TwiceShell();
        return const TwiceSignInPage();
      },
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F0),
        border: Border.all(color: const Color(0xFFFFCACA)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFFB42318),
          fontSize: 12,
          height: 1.45,
        ),
      ),
    );
  }
}

class TwiceSignInPage extends StatefulWidget {
  const TwiceSignInPage({
    super.key,
    this.configurationMissing = false,
    this.startupError,
  });

  final bool configurationMissing;
  final String? startupError;

  @override
  State<TwiceSignInPage> createState() => _TwiceSignInPageState();
}

class _TwiceSignInPageState extends State<TwiceSignInPage> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  bool _loading = false;
  bool _codeSent = false;
  String? _error;
  String? _message;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim().toLowerCase();

  Future<void> _sendCode() async {
    if (widget.configurationMissing || _loading) return;
    if (!_emailController.text.trim().contains('@')) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _message = null;
    });

    try {
      final localPart = _email.split('@').first;
      final username = localPart
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      final safeUsername = username.isEmpty
          ? 'twice_user'
          : username.substring(0, username.length > 24 ? 24 : username.length);

      final response =
          await Supabase.instance.client.functions.invoke(
        'twice-email-code',
        body: {
          'action': 'send_code',
          'email': _email,
          'username': safeUsername,
          'display_name': localPart,
        },
      );

      final data = response.data;
      if (response.status < 200 ||
          response.status >= 300 ||
          data is! Map ||
          data['ok'] != true) {
        throw Exception(
          data is Map
              ? (data['error'] ?? 'Could not send the verification code.')
              : 'Could not send the verification code.',
        );
      }

      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _message = 'If this address can receive mail, a code has been sent. '
            'Check your inbox and spam folder.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not send the code. ${e.toString()}';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyCode() async {
    if (widget.configurationMissing || _loading) return;
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter the six-digit code from your email.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _message = null;
    });

    try {
      final response =
          await Supabase.instance.client.functions.invoke(
        'twice-email-code',
        body: {
          'action': 'verify_code',
          'email': _email,
          'code': code,
        },
      );

      final data = response.data;
      if (response.status < 200 ||
          response.status >= 300 ||
          data is! Map ||
          data['ok'] != true ||
          data['token_hash'] is! String) {
        throw Exception(
          data is Map
              ? (data['error'] ?? 'The code could not be verified.')
              : 'The code could not be verified.',
        );
      }

      final tokenHash = data['token_hash'] as String;
      await Supabase.instance.client.auth.verifyOTP(
        tokenHash: tokenHash,
        type: OtpType.magiclink,
      );

      if (!mounted) return;
      setState(() {
        _message = 'Verified! Opening Twice...';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Verification failed. ${e.toString()}';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: canvas,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: violet,
                        borderRadius: BorderRadius.circular(25),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        't.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 49,
                          fontWeight: FontWeight.w900,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                  const Text(
                    'Welcome to Twice',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ink,
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Your people. Your moments. All in one place.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 15, height: 1.5),
                  ),
                  const SizedBox(height: 34),
                  TextField(
                    controller: _emailController,
                    enabled: !_loading && !_codeSent,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.email],
                    decoration: InputDecoration(
                      labelText: 'Email address',
                      hintText: 'you@example.com',
                      prefixIcon: const Icon(Icons.email_outlined),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: Color(0xFFE2E3EA)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: Color(0xFFE2E3EA)),
                      ),
                    ),
                  ),
                  if (_codeSent) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _codeController,
                      enabled: !_loading,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      maxLength: 6,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 10,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Six-digit email code',
                        hintText: '000000',
                        counterText: '',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _loading || widget.configurationMissing
                        ? null
                        : (_codeSent ? _verifyCode : _sendCode),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      backgroundColor: violet,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(17),
                      ),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            _codeSent ? 'Verify and continue' : 'Send email code',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                  if (_codeSent) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () {
                              setState(() {
                                _codeSent = false;
                                _codeController.clear();
                                _error = null;
                                _message = null;
                              });
                            },
                      child: const Text('Use a different email address'),
                    ),
                    TextButton(
                      onPressed: _loading ? null : _sendCode,
                      child: const Text('Resend code'),
                    ),
                  ],
                  if (widget.configurationMissing) ...[
                    const SizedBox(height: 18),
                    _ErrorPanel(
                      message: widget.startupError ??
                          'Supabase configuration is missing. Check the GitHub Actions build secrets.',
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _ErrorPanel(message: _error!),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF287A45),
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 30),
                  const Text(
                    'Secure email verification powered by Supabase.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "By continuing, you agree to Twice's Terms of Service "
                    'and Privacy Policy.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 11, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SocialPost {
  SocialPost(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'].toString();
  String get caption => (data['caption'] ?? '').toString();
  Map<String, dynamic> get author => Map<String, dynamic>.from(data['profiles'] as Map? ?? const {});
  String get name => (author['display_name'] ?? author['username'] ?? 'Twice user').toString();
  String get username => (author['username'] ?? 'user').toString();
  String get handle => '@$username';
  String? get avatarUrl => author['avatar_url']?.toString();
  List<Map<String, dynamic>> get media => (data['media_resolved'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  List<Map<String, dynamic>> get likesRows => (data['post_likes'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  bool get liked => likesRows.any((e) => e['user_id'] == Supabase.instance.client.auth.currentUser?.id);
  int get likes => likesRows.length;
  bool get saved => ((data['saved_posts'] as List? ?? const []).cast<Map>()).any((e) => e['user_id'] == Supabase.instance.client.auth.currentUser?.id);
}

class TwiceShell extends StatefulWidget {
  const TwiceShell({super.key});
  @override
  State<TwiceShell> createState() => _TwiceShellState();
}

class _TwiceShellState extends State<TwiceShell> {
  final repo = SocialRepository.instance;
  int selected = 0;
  bool loading = true;
  String? error;
  Map<String, dynamic> profile = {};
  List<SocialPost> posts = [];

  @override
  void initState() { super.initState(); _loadAll(); }

  Future<void> _loadAll() async {
    if (!mounted) return;
    setState(() { loading = true; error = null; });
    try {
      final values = await Future.wait<dynamic>([repo.myProfile(), repo.feed()]);
      if (!mounted) return;
      setState(() {
        profile = Map<String, dynamic>.from(values[0] as Map);
        posts = (values[1] as List<Map<String, dynamic>>).map(SocialPost.new).toList();
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = _friendlyError(e); });
    }
  }

  String _friendlyError(Object e) {
    final text = e.toString();
    if (text.contains('SocketException') || text.contains('Failed host lookup')) return 'No network connection. Check your internet and try again.';
    if (text.contains('duplicate key') || text.contains('23505')) return 'That username is already taken. Edit your profile to choose another.';
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<void> _like(SocialPost post) async {
    final wasLiked = post.liked;
    setState(() {
      final rows = List<Map<String, dynamic>>.from(post.data['post_likes'] as List? ?? []);
      final uid = Supabase.instance.client.auth.currentUser!.id;
      if (wasLiked) { rows.removeWhere((e) => e['user_id'] == uid); }
      else { rows.add({'user_id': uid}); }
      post.data['post_likes'] = rows;
    });
    try { await repo.toggleLike(post.id, wasLiked); }
    catch (e) { await _loadAll(); if (mounted) _message('Like failed: $e'); }
  }

  Future<void> _publish(String caption, List<AssetEntity> media) async {
    try {
      await repo.publishPost(caption, media);
      if (!mounted) return;
      setState(() => selected = 0);
      await _loadAll();
      if (mounted) _message('Post published.');
    } catch (e) { if (mounted) _message('Could not publish: $e'); rethrow; }
  }

  void _message(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final title = ['Twice', 'Search', 'Create', 'Activity', profile['username'] == null ? 'Profile' : '@${profile['username']}'][selected];
    return Scaffold(
      appBar: AppBar(title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 25)), actions: [
        IconButton(tooltip: 'Refresh', onPressed: _loadAll, icon: const Icon(Icons.refresh_rounded)),
        IconButton(tooltip: 'Messages', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MessagesPage())), icon: const Icon(Icons.send_outlined)),
      ]),
      body: loading && posts.isEmpty && profile.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : error != null && profile.isEmpty
              ? _ErrorPanel(message: error!)
              : IndexedStack(index: selected, children: [
                  FeedPage(posts: posts, onLike: _like, onRefresh: _loadAll, onCommentChanged: _loadAll),
                  const SearchPage(),
                  CreatePage(onPost: _publish),
                  const ActivityPage(),
                  ProfilePage(profile: profile, posts: posts, onRefresh: _loadAll),
                ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFFECE7FF),
        onDestinationSelected: (value) => setState(() => selected = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search_rounded), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.add_box_outlined), selectedIcon: Icon(Icons.add_box_rounded), label: 'Create'),
          NavigationDestination(icon: Icon(Icons.notifications_none_rounded), selectedIcon: Icon(Icons.notifications_rounded), label: 'Activity'),
          NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Profile'),
        ],
      ),
    );
  }
}


class StoryStrip extends StatelessWidget {
  const StoryStrip({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 104,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        children: [
          SizedBox(
            width: 70,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFD9D5E5), width: 1.7),
                  ),
                  child: const CircleAvatar(
                    radius: 29,
                    backgroundColor: Color(0xFFF0F0F4),
                    child: Icon(Icons.add_rounded, size: 29, color: ink),
                  ),
                ),
                const SizedBox(height: 5),
                const Text('Your story', maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: ink)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class FeedPage extends StatelessWidget {
  const FeedPage({
    super.key,
    required this.posts,
    required this.onLike,
    required this.onRefresh,
    required this.onCommentChanged,
  });

  final List<SocialPost> posts;
  final ValueChanged<SocialPost> onLike;
  final Future<void> Function() onRefresh;
  final VoidCallback onCommentChanged;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
      children: [
        const StoryStrip(),
        const SizedBox(height: 5),
        if (posts.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 70),
            child: Column(
              children: [
                Icon(Icons.dynamic_feed_outlined, size: 56, color: muted),
                SizedBox(height: 14),
                Text('No posts yet',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
                SizedBox(height: 7),
                Text('Follow people or share your first moment.',
                  style: TextStyle(color: muted)),
              ],
            ),
          )
        else
          ...posts.map((post) => PostCard(
            post: post,
            onLike: onLike,
            onCommentChanged: onCommentChanged,
          )),
      ],
    ),
  );
}



class _AnimatedLikeButton extends StatefulWidget {
  const _AnimatedLikeButton({
    required this.liked,
    required this.onPressed,
  });

  final bool liked;
  final VoidCallback onPressed;

  @override
  State<_AnimatedLikeButton> createState() => _AnimatedLikeButtonState();
}

class _AnimatedLikeButtonState extends State<_AnimatedLikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.35)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.35, end: 1.0)
          .chain(CurveTween(curve: Curves.easeInOut)),
      weight: 55,
    ),
  ]).animate(_controller);

  @override
  void didUpdateWidget(covariant _AnimatedLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.liked != widget.liked) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.liked ? 'Unlike post' : 'Like post',
    onPressed: () {
      _controller.forward(from: 0);
      widget.onPressed();
    },
    icon: ScaleTransition(
      scale: _scale,
      child: Icon(
        widget.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        size: 27,
        color: widget.liked ? Colors.redAccent : ink,
      ),
    ),
  );
}

class PostCard extends StatelessWidget {
  const PostCard({
    super.key,
    required this.post,
    required this.onLike,
    required this.onCommentChanged,
  });

  final SocialPost post;
  final ValueChanged<SocialPost> onLike;
  final VoidCallback onCommentChanged;

  @override
  Widget build(BuildContext context) {
    final media = post.media;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEDEDED)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 12, 8, 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: const Color(0xFFF0F2F5),
                  backgroundImage: post.avatarUrl == null
                      ? null
                      : NetworkImage(post.avatarUrl!),
                  child: post.avatarUrl == null
                      ? const Icon(Icons.person_outline_rounded, color: muted)
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${post.handle} · ${_timeAgo(post.data['created_at'])}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: muted),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Post options',
                  icon: const Icon(Icons.more_horiz_rounded, color: ink),
                  onSelected: (value) {
                    if (value == 'copy') {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Use your device share options to share this post.'),
                        ),
                      );
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'copy',
                      child: Row(
                        children: [
                          Icon(Icons.ios_share_rounded, size: 19),
                          SizedBox(width: 10),
                          Text('Share options'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (post.caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Text(
                post.caption,
                style: const TextStyle(
                  color: ink,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ),

          if (media.isNotEmpty)
            AspectRatio(
              aspectRatio: media.length == 1 ? 1 : 0.92,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PageView.builder(
                    itemCount: media.length,
                    itemBuilder: (context, index) {
                      final url = (media[index]['resolved_url'] ?? '').toString();
                      return ColoredBox(
                        color: const Color(0xFFF4F5F7),
                        child: url.isEmpty
                            ? const Center(
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 42,
                                  color: muted,
                                ),
                              )
                            : Image.network(
                                url,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                errorBuilder: (_, _, _) => const Center(
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    size: 42,
                                    color: muted,
                                  ),
                                ),
                              ),
                      );
                    },
                  ),
                  if (media.length > 1)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xB8000000),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          child: Text(
                            '${media.length} photos/videos',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _AnimatedLikeButton(
                      liked: post.liked,
                      onPressed: () => onLike(post),
                    ),
                    IconButton(
                      tooltip: 'Comments',
                      onPressed: () async {
                        await showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (_) => CommentsSheet(post: post),
                        );
                        onCommentChanged();
                      },
                      icon: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 25,
                        color: ink,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: post.saved ? 'Remove saved post' : 'Save post',
                      onPressed: () async {
                        final wasSaved = post.saved;
                        try {
                          await SocialRepository.instance.toggleSaved(
                            post.id,
                            wasSaved,
                          );
                          onCommentChanged();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  wasSaved
                                      ? 'Post removed from saved'
                                      : 'Post saved',
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Could not save post: $e')),
                            );
                          }
                        }
                      },
                      icon: Icon(
                        post.saved
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        size: 26,
                        color: post.saved
                            ? const Color(0xFFE2B900)
                            : ink,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Text(
                    '${post.likes} ${post.likes == 1 ? 'like' : 'likes'}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: ink,
                    ),
                  ),
                ),
                if (post.caption.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${post.handle}  ',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          TextSpan(text: post.caption),
                        ],
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _timeAgo(dynamic value) {
  final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (date == null) return '';
  final diff = DateTime.now().difference(date);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${date.day}/${date.month}/${date.year}';
}

class CreatePage extends StatefulWidget {
  const CreatePage({super.key, required this.onPost});
  final Future<void> Function(String caption, List<AssetEntity> media) onPost;
  @override
  State<CreatePage> createState() => _CreatePageState();
}
class _CreatePageState extends State<CreatePage> {
  final controller = TextEditingController();
  final selectedMedia = <AssetEntity>[];
  bool publishing = false;
  @override
  void dispose() { controller.dispose(); super.dispose(); }
  Future<void> _pick() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Allow photo access to select media.'))); return; }
    final paths = await PhotoManager.getAssetPathList(type: RequestType.common, onlyAll: true);
    if (paths.isEmpty) return;
    final assets = await paths.first.getAssetListPaged(page: 0, size: 100);
    if (!mounted) return;
    final picked = await showModalBottomSheet<List<AssetEntity>>(context: context, isScrollControlled: true, builder: (context) => _MediaPicker(assets: assets));
    if (picked != null) setState(() { selectedMedia..clear()..addAll(picked.take(10)); });
  }
  Future<void> _publish() async {
    if (publishing) return;
    setState(() => publishing = true);
    try { await widget.onPost(controller.text, selectedMedia); controller.clear(); setState(() => selectedMedia.clear()); }
    catch (_) {} finally { if (mounted) setState(() => publishing = false); }
  }
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('Create a post', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900)), const SizedBox(height: 16),
    TextField(controller: controller, minLines: 4, maxLines: 10, maxLength: 5000, decoration: InputDecoration(hintText: "What's happening?", filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none))),
    OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.photo_library_outlined), label: Text(selectedMedia.isEmpty ? 'Add photos or videos' : '${selectedMedia.length} media selected')),
    if (selectedMedia.isNotEmpty)
      SizedBox(
        height: 95,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: selectedMedia.map((asset) => Padding(
            padding: const EdgeInsets.all(4),
            child: FutureBuilder<Uint8List?>(
              future: asset.thumbnailDataWithSize(const ThumbnailSize(180, 180)),
              builder: (_, snapshot) => snapshot.data == null
                ? const SizedBox(width: 80, child: Center(child: CircularProgressIndicator()))
                : Image.memory(snapshot.data!, width: 80, height: 80, fit: BoxFit.cover),
            ),
          )).toList(),
        ),
      ),
    const SizedBox(height: 12), FilledButton(onPressed: publishing ? null : _publish, child: Text(publishing ? 'Publishing…' : 'Publish post')),
  ]);
}

class _MediaPicker extends StatefulWidget {
  const _MediaPicker({required this.assets}); final List<AssetEntity> assets;
  @override State<_MediaPicker> createState() => _MediaPickerState();
}
class _MediaPickerState extends State<_MediaPicker> {
  final Set<AssetEntity> chosen = {};
  @override Widget build(BuildContext context) => SizedBox(height: MediaQuery.sizeOf(context).height * .78, child: Column(children: [ListTile(title: const Text('Select media', style: TextStyle(fontWeight: FontWeight.w800)), trailing: TextButton(onPressed: () => Navigator.pop(context, chosen.toList()), child: const Text('Done'))), Expanded(child: GridView.builder(padding: const EdgeInsets.all(4), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 3, mainAxisSpacing: 3), itemCount: widget.assets.length, itemBuilder: (_, i) { final a = widget.assets[i]; return InkWell(onTap: () => setState(() { if (chosen.contains(a)) { chosen.remove(a); } else if (chosen.length < 10) { chosen.add(a); } }), child: Stack(fit: StackFit.expand, children: [FutureBuilder<Uint8List?>(future: a.thumbnailDataWithSize(const ThumbnailSize(220, 220)), builder: (_, s) => s.data == null ? const ColoredBox(color: canvas) : Image.memory(s.data!, fit: BoxFit.cover)), if (a.type == AssetType.video) const Align(alignment: Alignment.bottomRight, child: Icon(Icons.play_circle_fill, color: Colors.white)), if (chosen.contains(a)) const Align(alignment: Alignment.topRight, child: Icon(Icons.check_circle, color: violet))])); }))]));
}

class SearchPage extends StatefulWidget { const SearchPage({super.key}); @override State<SearchPage> createState() => _SearchPageState(); }
class _SearchPageState extends State<SearchPage> {
  final controller = TextEditingController(); List<Map<String, dynamic>> results = []; bool busy = false; String? error;
  @override void dispose() { controller.dispose(); super.dispose(); }
  Future<void> _search(String q) async {
    if (q.trim().isEmpty) { setState(() { results = []; error = null; }); return; }
    setState(() { busy = true; error = null; });
    try { final data = await SocialRepository.instance.search(q); if (mounted) setState(() => results = data); }
    catch (e) { if (mounted) setState(() => error = e.toString()); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext context) => Column(children: [Padding(padding: const EdgeInsets.all(16), child: TextField(controller: controller, onChanged: _search, decoration: InputDecoration(hintText: 'Search people by name or @username', prefixIcon: const Icon(Icons.search), suffixIcon: IconButton(onPressed: () { controller.clear(); _search(''); }, icon: const Icon(Icons.close)), filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none)))), if (busy) const LinearProgressIndicator(), if (error != null) Padding(padding: const EdgeInsets.all(16), child: Text(error!, style: const TextStyle(color: Colors.red))), Expanded(child: results.isEmpty ? Center(child: Text(controller.text.isEmpty ? 'Search for real Twice users' : 'No users found', style: const TextStyle(color: muted))) : ListView.builder(itemCount: results.length, itemBuilder: (_, i) => _UserTile(user: results[i])))]);
}

class _UserTile extends StatefulWidget {
  const _UserTile({required this.user}); final Map<String, dynamic> user;
  @override State<_UserTile> createState() => _UserTileState();
}
class _UserTileState extends State<_UserTile> {
  bool following = false, busy = false;
  @override Widget build(BuildContext context) {
    final user = widget.user;
    if (user['result_type'] == 'post') {
      final author = user['profiles'] as Map? ?? {};
      return ListTile(leading: const CircleAvatar(child: Icon(Icons.article_outlined)), title: Text((user['caption'] ?? 'Media post').toString(), maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Text('${author['display_name'] ?? author['username'] ?? 'Twice user'} · @${author['username'] ?? 'user'}'));
    }
    final isSelf = user['id'] == Supabase.instance.client.auth.currentUser?.id;
    return ListTile(
      leading: CircleAvatar(backgroundImage: user['avatar_url'] == null ? null : NetworkImage(user['avatar_url'].toString()), child: user['avatar_url'] == null ? const Icon(Icons.person) : null),
      title: Text((user['display_name'] ?? user['username'] ?? 'Twice user').toString(), style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text('@${user['username'] ?? 'user'}'),
      trailing: isSelf ? null : Wrap(children: [
        TextButton(onPressed: busy ? null : () async { setState(() => busy = true); try { if (following) { await SocialRepository.instance.unfollow(user['id'].toString()); } else { await SocialRepository.instance.follow(user['id'].toString(), privateAccount: user['is_private'] == true); } if (mounted) setState(() => following = !following); } catch (e) { if (mounted) { ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('Follow action failed: $e'))); } } finally { if (mounted) setState(() => busy = false); } }, child: Text(busy ? '…' : following ? 'Following' : 'Follow')),
        IconButton(tooltip: 'Message', onPressed: busy ? null : () async { setState(() => busy = true); try { final id = await SocialRepository.instance.createConversation(user['id'].toString()); if (context.mounted) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ConversationPage(id: id, title: (user['display_name'] ?? user['username'] ?? 'Message').toString()))); } catch (e) { if (mounted) { ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('Could not start conversation: $e'))); } } finally { if (mounted) setState(() => busy = false); } }, icon: const Icon(Icons.send_outlined)),
      ]),
    );
  }
}

class CommentsSheet extends StatefulWidget { const CommentsSheet({super.key, required this.post}); final SocialPost post; @override State<CommentsSheet> createState() => _CommentsSheetState(); }
class _CommentsSheetState extends State<CommentsSheet> {
  final controller = TextEditingController(); List<Map<String, dynamic>> rows = []; bool busy = true;
  @override void initState() { super.initState(); _load(); }
  @override void dispose() { controller.dispose(); super.dispose(); }
  Future<void> _load() async { try { final data = await SocialRepository.instance.comments(widget.post.id); if (mounted) setState(() { rows = data; busy = false; }); } catch (e) { if (mounted) setState(() => busy = false); } }
  Future<void> _send() async { final text = controller.text.trim(); if (text.isEmpty) return; try { await SocialRepository.instance.addComment(widget.post.id, text); controller.clear(); await _load(); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Comment failed: $e'))); } }
  @override Widget build(BuildContext context) => SafeArea(child: SizedBox(height: MediaQuery.sizeOf(context).height * .72, child: Column(children: [const Padding(padding: EdgeInsets.all(16), child: Text('Comments', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))), Expanded(child: busy ? const Center(child: CircularProgressIndicator()) : rows.isEmpty ? const Center(child: Text('No comments yet')) : ListView.builder(itemCount: rows.length, itemBuilder: (_, i) { final r = rows[i]; final p = r['profiles'] as Map? ?? {}; return ListTile(title: Text((p['display_name'] ?? p['username'] ?? 'User').toString()), subtitle: Text((r['body'] ?? '').toString())); })), Padding(padding: EdgeInsets.fromLTRB(12, 8, 12, MediaQuery.viewInsetsOf(context).bottom + 12), child: Row(children: [Expanded(child: TextField(controller: controller, decoration: const InputDecoration(hintText: 'Write a comment…'))), IconButton(onPressed: _send, icon: const Icon(Icons.send, color: violet))]))])));
}

class ActivityPage extends StatefulWidget {
  const ActivityPage({super.key});

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  late Future<List<Map<String, dynamic>>> future;

  @override
  void initState() {
    super.initState();
    future = SocialRepository.instance.notifications();
  }

  Future<void> _refresh() async {
    setState(() => future = SocialRepository.instance.notifications());
    await future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Could not load activity: ${snapshot.error}'),
          );
        }
        final rows = snapshot.data ?? [];
        if (rows.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 180),
                Center(
                  child: Text('No activity yet', style: TextStyle(color: muted)),
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              final actor = row['profiles'] as Map? ?? {};
              return ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.notifications_none),
                ),
                title: Text(
                  '${actor['display_name'] ?? actor['username'] ?? 'Someone'} '
                  '${row['type'] ?? 'interacted'} with you',
                ),
                subtitle: Text(_timeAgo(row['created_at'])),
              );
            },
          ),
        );
      },
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.profile,
    required this.posts,
    required this.onRefresh,
  });

  final Map<String, dynamic> profile;
  final List<SocialPost> posts;
  final Future<void> Function() onRefresh;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  int selectedTab = 0;
  int followersCount = 0;
  int followingCount = 0;
  bool _countsLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFollowCounts();
  }

  Future<void> _loadFollowCounts() async {
    final id = (widget.profile['id'] ?? '').toString();
    if (id.isEmpty) {
      if (mounted) setState(() => _countsLoading = false);
      return;
    }
    try {
      final db = Supabase.instance.client;
      final values = await Future.wait<List<dynamic>>([
        db.from('follows').select('follower_id').eq('following_id', id).eq('status', 'accepted'),
        db.from('follows').select('following_id').eq('follower_id', id).eq('status', 'accepted'),
      ]);
      if (!mounted) return;
      setState(() {
        followersCount = values[0].length;
        followingCount = values[1].length;
        _countsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _countsLoading = false);
    }
  }

  @override
  void didUpdateWidget(covariant ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile['id'] != widget.profile['id']) {
      _countsLoading = true;
      _loadFollowCounts();
    }
  }

  List<SocialPost> get _myPosts => widget.posts
      .where((p) =>
          p.data['user_id'] ==
          Supabase.instance.client.auth.currentUser?.id)
      .toList();

  List<SocialPost> get _visiblePosts {
    if (selectedTab == 1) {
      return _myPosts.where((p) => p.media.any((m) =>
          (m['media_type'] ?? '').toString().toLowerCase() == 'image')).toList();
    }
    if (selectedTab == 2) {
      return _myPosts.where((p) => p.media.any((m) =>
          (m['media_type'] ?? '').toString().toLowerCase() == 'video')).toList();
    }
    return _myPosts;
  }

  Future<void> _edit() async {
    final display = TextEditingController(
      text: (widget.profile['display_name'] ?? '').toString(),
    );
    final username = TextEditingController(
      text: (widget.profile['username'] ?? '').toString(),
    );
    final bio = TextEditingController(
      text: (widget.profile['bio'] ?? '').toString(),
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit profile'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: display,
                decoration: const InputDecoration(labelText: 'Display name'),
              ),
              TextField(
                controller: username,
                decoration: const InputDecoration(labelText: '@username'),
              ),
              TextField(
                controller: bio,
                maxLines: 3,
                maxLength: 160,
                decoration: const InputDecoration(labelText: 'Bio'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      try {
        await SocialRepository.instance.updateProfile(
          displayName: display.text,
          username: username.text,
          bio: bio.text,
        );
        await widget.onRefresh();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile updated')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Profile update failed: $e')),
          );
        }
      }
    }

    display.dispose();
    username.dispose();
    bio.dispose();
  }

  Future<void> _shareProfile() async {
    final username = (widget.profile['username'] ?? '').toString();
    final profileUrl = 'https://twice.app/@$username';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 29,
              backgroundImage: widget.profile['avatar_url'] == null
                  ? null
                  : NetworkImage(widget.profile['avatar_url'].toString()),
              child: widget.profile['avatar_url'] == null
                  ? const Icon(Icons.person, size: 30)
                  : null,
            ),
            const SizedBox(height: 10),
            Text(
              (widget.profile['display_name'] ?? username).toString(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text('@$username', style: const TextStyle(color: muted)),
            const SizedBox(height: 18),
            QrImageView(
              data: profileUrl,
              version: QrVersions.auto,
              size: 210,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 8),
            const Text(
              'Scan to find this profile',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: profileUrl));
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Profile link copied')),
                );
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy profile link'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label) => Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(color: muted, fontSize: 12)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final username = (profile['username'] ?? '').toString();
    final bio = (profile['bio'] ?? '').toString();
    final posts = _visiblePosts;

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    username.isEmpty ? 'Your profile' : '@$username',
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Share profile',
                  onPressed: _shareProfile,
                  icon: const Icon(Icons.qr_code_rounded),
                ),
                IconButton(
                  tooltip: 'Edit profile',
                  onPressed: _edit,
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 43,
                  backgroundColor: const Color(0xFFF0F2F5),
                  backgroundImage: profile['avatar_url'] == null
                      ? null
                      : NetworkImage(profile['avatar_url'].toString()),
                  child: profile['avatar_url'] == null
                      ? const Icon(Icons.person_outline_rounded, size: 43)
                      : null,
                ),
                const SizedBox(width: 22),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _stat('${_myPosts.length}', 'Posts'),
                      _stat(_countsLoading ? '…' : '$followersCount', 'Followers'),
                      _stat(_countsLoading ? '…' : '$followingCount', 'Following'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 15, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((profile['display_name'] ?? '').toString().trim().isNotEmpty)
                  Text(
                    profile['display_name'].toString().trim(),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                if (bio.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(bio, style: const TextStyle(height: 1.4)),
                ],
                const SizedBox(height: 13),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _edit,
                        child: const Text('Edit profile'),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _shareProfile,
                        icon: const Icon(Icons.share_outlined, size: 18),
                        label: const Text('Share profile'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFEDEDED)),
          Row(
            children: [
              _profileTab(0, Icons.grid_on_rounded, 'Posts'),
              _profileTab(1, Icons.photo_outlined, 'Photos'),
              _profileTab(2, Icons.play_circle_outline_rounded, 'Videos'),
            ],
          ),
          const Divider(height: 1, color: Color(0xFFEDEDED)),
          if (posts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 55, horizontal: 24),
              child: Column(
                children: [
                  const Icon(Icons.photo_library_outlined, size: 43, color: muted),
                  const SizedBox(height: 12),
                  Text(
                    selectedTab == 0
                        ? 'No posts yet'
                        : selectedTab == 1
                            ? 'No photos yet'
                            : 'No videos yet',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Share a moment and it will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted),
                  ),
                ],
              ),
            )
          else
            ...posts.map(
              (post) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: PostCard(
                  post: post,
                  onLike: (item) async {
                    final wasLiked = item.liked;
                    final uid = Supabase.instance.client.auth.currentUser?.id;
                    if (uid == null) return;
                    final rows = List<Map<String, dynamic>>.from(
                      item.data['post_likes'] as List? ?? [],
                    );
                    setState(() {
                      if (wasLiked) {
                        rows.removeWhere((e) => e['user_id'] == uid);
                      } else {
                        rows.add({'user_id': uid});
                      }
                      item.data['post_likes'] = rows;
                    });
                    try {
                      await SocialRepository.instance.toggleLike(item.id, wasLiked);
                    } catch (e) {
                      await widget.onRefresh();
                      if (mounted) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(content: Text('Like failed: $e')),
                        );
                      }
                    }
                  },
                  onCommentChanged: widget.onRefresh,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _profileTab(int index, IconData icon, String label) {
    final active = selectedTab == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => selectedTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? ink : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: active ? ink : muted),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                  color: active ? ink : muted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MessagesPage extends StatefulWidget { const MessagesPage({super.key}); @override State<MessagesPage> createState() => _MessagesPageState(); }
class _MessagesPageState extends State<MessagesPage> {
  late Future<List<Map<String, dynamic>>> future;
  @override void initState() { super.initState(); future = SocialRepository.instance.conversations(); }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Messages')), body: FutureBuilder<List<Map<String, dynamic>>>(future: future, builder: (_, s) { if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator()); if (s.hasError) return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('Could not load conversations: ${s.error}'))); final rows = s.data ?? []; if (rows.isEmpty) return const Center(child: Text('No conversations yet')); return ListView.builder(itemCount: rows.length, itemBuilder: (_, i) { final r = rows[i]; final c = r['conversations'] as Map? ?? {}; return ListTile(leading: const CircleAvatar(child: Icon(Icons.person)), title: Text((c['title'] ?? 'Conversation').toString()), subtitle: const Text('Open conversation'), onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ConversationPage(id: r['conversation_id'].toString(), title: (c['title'] ?? 'Conversation').toString())))); }); }));
}
class ConversationPage extends StatefulWidget { const ConversationPage({super.key, required this.id, required this.title}); final String id, title; @override State<ConversationPage> createState() => _ConversationPageState(); }
class _ConversationPageState extends State<ConversationPage> {
  final controller = TextEditingController(); late Future<List<Map<String, dynamic>>> future;
  @override void initState() { super.initState(); future = SocialRepository.instance.messages(widget.id); }
  @override void dispose() { controller.dispose(); super.dispose(); }
  Future<void> _send() async { try { await SocialRepository.instance.sendMessage(widget.id, controller.text); controller.clear(); setState(() => future = SocialRepository.instance.messages(widget.id)); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Message failed: $e'))); } }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(widget.title)), body: Column(children: [Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(future: future, builder: (_, s) { if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator()); if (s.hasError) return Center(child: Text('Could not load messages: ${s.error}')); final rows = s.data ?? []; return ListView.builder(reverse: false, padding: const EdgeInsets.all(12), itemCount: rows.length, itemBuilder: (_, i) { final r = rows[i]; final own = r['sender_id'] == Supabase.instance.client.auth.currentUser?.id; return Align(alignment: own ? Alignment.centerRight : Alignment.centerLeft, child: Container(margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: own ? const Color(0xFFECE7FF) : Colors.white, borderRadius: BorderRadius.circular(16)), child: Text((r['body'] ?? '').toString()))); }); })), SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [Expanded(child: TextField(controller: controller, decoration: const InputDecoration(hintText: 'Message…'))), IconButton(onPressed: _send, icon: const Icon(Icons.send, color: violet))])))]));
}
