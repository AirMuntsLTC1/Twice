import 'dart:async';
import 'dart:ffi' hide Size;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/social_repository.dart';

const ink = Color(0xFF171923);
const muted = Color(0xFF7B8191);
const violet = Color(0xFF7257F5);
const canvas = Color(0xFFF7F7FB);

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabasePublishableKey = String.fromEnvironment(
  'SUPABASE_PUBLISHABLE_KEY',
);

bool get supabaseConfigured =>
    supabaseUrl.startsWith('https://') && supabasePublishableKey.isNotEmpty;

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

      final response = await Supabase.instance.client.functions.invoke(
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
        _message =
            'If this address can receive mail, a code has been sent. '
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
      final response = await Supabase.instance.client.functions.invoke(
        'twice-email-code',
        body: {'action': 'verify_code', 'email': _email, 'code': code},
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
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 48,
              ),
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
                            _codeSent
                                ? 'Verify and continue'
                                : 'Send email code',
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
                      message: widget.startupError ?? 'Supabase configuration is missing. Check the GitHub Actions build secrets.',
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
  Map<String, dynamic> get author =>
      Map<String, dynamic>.from(data['profiles'] as Map? ?? const {});
  String get name =>
      (author['display_name'] ?? author['username'] ?? 'Twice user').toString();
  String get username => (author['username'] ?? 'user').toString();
  String get handle => '@$username';
  String? get avatarUrl => author['avatar_url']?.toString();
  List<Map<String, dynamic>> get media =>
      (data['media_resolved'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  List<Map<String, dynamic>> get likesRows =>
      (data['post_likes'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  bool get liked => likesRows.any(
    (e) => e['user_id'] == Supabase.instance.client.auth.currentUser?.id,
  );
  int get likes => likesRows.length;
  bool get saved =>
      ((data['saved_posts'] as List? ?? const []).cast<Map>()).any(
        (e) => e['user_id'] == Supabase.instance.client.auth.currentUser?.id,
      );
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
  List<Map<String, dynamic>> stories = [];
  final GlobalKey<StoryStripState> _storyStripKey =
      GlobalKey<StoryStripState>();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _syncPendingLikes() async {
    try {
      await repo.syncPendingLikes();
    } catch (e) {
      debugPrint('Twice pending-like sync deferred: $e');
    }
  }

  Future<void> _loadAll() async {
    if (!mounted) return;
    _syncPendingLikes(); // Replay in background; show cached content immediately.
    setState(() {
      loading = true;
      error = null;
    });
    // Render durable local data first. The network refresh below updates the
    // same UI after the cache has already appeared, avoiding a blank cold start.
    try {
      final cached = await Future.wait<dynamic>([
        repo.cachedMyProfile(),
        repo.cachedFeed(),
      ]);
      if (!mounted) return;
      final cachedProfile = cached[0];
      final cachedPosts = cached[1] as List<Map<String, dynamic>>;
      if (cachedProfile is Map || cachedPosts.isNotEmpty) {
        setState(() {
          if (cachedProfile is Map) {
            profile = Map<String, dynamic>.from(cachedProfile);
          }
          if (cachedPosts.isNotEmpty) {
            posts = cachedPosts.map(SocialPost.new).toList();
          }
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      /* A first install simply has an empty cache. */
    }
    try {
      final values = await Future.wait<dynamic>([
        repo.myProfile(),
        repo.feed(),
        repo.loadStories().catchError((_) => <Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      setState(() {
        profile = Map<String, dynamic>.from(values[0] as Map);
        posts = (values[1] as List<Map<String, dynamic>>)
            .map(SocialPost.new)
            .toList();
        stories = values[2] as List<Map<String, dynamic>>;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = posts.isNotEmpty || profile.isNotEmpty
            ? null
            : _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object e) {
    final text = e.toString();
    if (text.contains('SocketException') ||
        text.contains('Failed host lookup')) {
      return 'No network connection. Check your internet and try again.';
    }
    if (text.contains('duplicate key') || text.contains('23505')) {
      return 'That username is already taken. Edit your profile to choose another.';
    }
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<void> _like(SocialPost post) async {
    final wasLiked = post.liked;
    setState(() {
      final rows = List<Map<String, dynamic>>.from(
        post.data['post_likes'] as List? ?? [],
      );
      final uid = Supabase.instance.client.auth.currentUser!.id;
      if (wasLiked) {
        rows.removeWhere((e) => e['user_id'] == uid);
      } else {
        rows.add({'user_id': uid});
      }
      post.data['post_likes'] = rows;
    });
    try {
      await repo.toggleLike(post.id, wasLiked);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final rows = List<Map<String, dynamic>>.from(
          post.data['post_likes'] as List? ?? [],
        );
        final uid = Supabase.instance.client.auth.currentUser?.id;
        rows.removeWhere((row) => row['user_id'] == uid);
        if (wasLiked && uid != null) rows.add({'user_id': uid});
        post.data['post_likes'] = rows;
      });
      _message('Like could not sync: $e');
    }
  }

  Future<void> _publish(String caption, List<AssetEntity> media) async {
    try {
      await repo.publishPost(caption, media);
      if (!mounted) return;
      setState(() => selected = 0);
      await _loadAll();
      if (mounted) _message('Post published.');
    } catch (e) {
      if (mounted) _message('Could not publish: $e');
      rethrow;
    }
  }

  void _openComposer() {
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, animation, secondaryAnimation) =>
            CreatePage(onPost: _publish),
        transitionsBuilder: (_, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  void _message(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final title = [
      'Twice',
      'Search',
      'Create',
      'Activity',
      'Profile',
    ][selected];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 25),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Create',
            offset: const Offset(0, 48),
            position: PopupMenuPosition.under,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            elevation: 10,
            onSelected: (value) {
              if (value == 'create') {
                _openComposer();
              } else if (value == 'story') {
                setState(() => selected = 0);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _storyStripKey.currentState?.openCreator();
                });
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'create',
                child: Row(
                  children: [
                    Icon(Icons.post_add_rounded, color: violet),
                    SizedBox(width: 12),
                    Text(
                      'Create post',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'story',
                child: Row(
                  children: [
                    Icon(Icons.add_circle_outline_rounded, color: violet),
                    SizedBox(width: 12),
                    Text(
                      'Create story',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
            child: Container(
              width: 40,
              height: 40,
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: violet,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 27,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Messages',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MessagesPage()),
            ),
            icon: const Icon(Icons.send_outlined),
          ),
        ],
      ),
      body: loading && posts.isEmpty && profile.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : error != null && profile.isEmpty
          ? _ErrorPanel(message: error!)
          : IndexedStack(
              index: selected,
              children: [
                FeedPage(
                  storyStripKey: _storyStripKey,
                  profile: profile,
                  stories: stories,
                  onCreateStory: (asset, caption) async {
                    await repo.publishStory(asset, caption);
                    await _loadAll();
                  },
                  posts: posts,
                  onLike: _like,
                  onRefresh: _loadAll,
                  onOpenComposer: _openComposer,
                  onCommentChanged: () {
                    if (mounted) setState(() {});
                  },
                ),
                const SearchPage(),
                const SizedBox.shrink(),
                const ActivityPage(),
                ProfilePage(
                  profile: profile,
                  posts: posts,
                  onRefresh: _loadAll,
                ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFFECE7FF),
        onDestinationSelected: (value) {
          if (value == 2) {
            _openComposer();
          } else {
            setState(() => selected = value);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_rounded),
            label: 'Search',
          ),
          NavigationDestination(
            icon: Icon(Icons.add_box_outlined),
            selectedIcon: Icon(Icons.add_box_rounded),
            label: 'Create',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_none_rounded),
            selectedIcon: Icon(Icons.notifications_rounded),
            label: 'Activity',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class StoryStrip extends StatefulWidget {
  const StoryStrip({
    super.key,
    required this.onCreateStory,
    required this.profile,
    required this.stories,
  });

  final Future<void> Function(AssetEntity asset, String caption) onCreateStory;
  final Map<String, dynamic> profile;
  final List<Map<String, dynamic>> stories;

  @override
  State<StoryStrip> createState() => StoryStripState();
}

class StoryStripState extends State<StoryStrip> {
  Future<void> openCreator() async {
    final context = this.context;
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Allow photo access to create a story.'),
          ),
        );
      }
      return;
    }

    final imagePaths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    final videoPaths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      onlyAll: true,
    );
    final assets = <AssetEntity>[];
    if (imagePaths.isNotEmpty) {
      assets.addAll(
        await imagePaths.first.getAssetListPaged(page: 0, size: 100),
      );
    }
    if (videoPaths.isNotEmpty) {
      assets.addAll(
        await videoPaths.first.getAssetListPaged(page: 0, size: 100),
      );
    }
    assets.sort(
      (a, b) => (b.createDateSecond ?? 0).compareTo(a.createDateSecond ?? 0),
    );

    if (!context.mounted) return;
    if (assets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No photos or videos found.')),
      );
      return;
    }

    final asset = await showModalBottomSheet<AssetEntity>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * .68,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Choose one photo or video',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
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
                  itemBuilder: (context, index) {
                    final item = assets[index];
                    return FutureBuilder<Uint8List?>(
                      future: item.thumbnailDataWithSize(
                        const ThumbnailSize(240, 240),
                      ),
                      builder: (context, snapshot) => InkWell(
                        onTap: () => Navigator.pop(sheetContext, item),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (snapshot.data != null)
                              Image.memory(snapshot.data!, fit: BoxFit.cover)
                            else
                              const ColoredBox(
                                color: Color(0xFFF0F0F4),
                                child: Icon(Icons.image_outlined),
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
    if (asset == null || !context.mounted) return;

    final controller = TextEditingController();
    final caption = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          20,
          16,
          MediaQuery.of(sheetContext).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Create story',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLength: 300,
              decoration: const InputDecoration(
                hintText: 'Write a caption (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(sheetContext, controller.text),
                child: const Text('Share story'),
              ),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (caption == null || !context.mounted) return;

    try {
      await widget.onCreateStory(asset, caption);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Story shared for 24 hours.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not share story: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ownId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final story in widget.stories) {
      final uid = (story['user_id'] ?? '').toString();
      if (uid.isNotEmpty) (grouped[uid] ??= []).add(story);
    }
    final ownStories = grouped.remove(ownId) ?? [];
    final otherIds = grouped.keys.toList();

    return SizedBox(
      height: 104,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        children: [
          _storyCircle(
            context,
            profile: widget.profile,
            stories: ownStories,
            label: 'Your story',
            own: true,
          ),
          ...otherIds.map((uid) {
            final rows = grouped[uid]!;
            final user = Map<String, dynamic>.from(
              rows.first['profiles'] as Map? ?? const {},
            );
            final label =
                (user['display_name'] ?? user['username'] ?? 'Twice user')
                    .toString();
            return _storyCircle(
              context,
              profile: user,
              stories: rows,
              label: label,
              own: false,
            );
          }),
        ],
      ),
    );
  }

  Widget _storyCircle(
    BuildContext context, {
    required Map<String, dynamic> profile,
    required List<Map<String, dynamic>> stories,
    required String label,
    required bool own,
  }) {
    final avatar = (profile['avatar_url'] ?? '').toString().trim();
    return SizedBox(
      width: 76,
      child: InkWell(
        borderRadius: BorderRadius.circular(42),
        onTap: () {
          if (stories.isEmpty) {
            if (own) openCreator();
            return;
          }
          Navigator.of(context).push(
            PageRouteBuilder<void>(
              opaque: true,
              transitionDuration: const Duration(milliseconds: 360),
              pageBuilder: (_, animation, _) =>
                  StoryViewer(stories: stories, initialProfile: profile),
              transitionsBuilder: (_, animation, _, child) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: .88, end: 1).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
                  child: child,
                ),
              ),
            ),
          );
        },
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: stories.isNotEmpty
                        ? const LinearGradient(
                            colors: [
                              Color(0xFFF9CE34),
                              Color(0xFFEE2A7B),
                              Color(0xFF6228D7),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    border: stories.isEmpty
                        ? Border.all(color: const Color(0xFFD9D5E5), width: 1.7)
                        : null,
                  ),
                  child: CircleAvatar(
                    radius: 29,
                    backgroundColor: const Color(0xFFF0F0F4),
                    backgroundImage: avatar.startsWith('http')
                        ? NetworkImage(avatar)
                        : null,
                    child: avatar.startsWith('http')
                        ? null
                        : const Icon(
                            Icons.person_rounded,
                            color: muted,
                            size: 30,
                          ),
                  ),
                ),
                if (own)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 23,
                      height: 23,
                      decoration: BoxDecoration(
                        color: violet,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(
                        Icons.add_rounded,
                        size: 17,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: ink),
            ),
          ],
        ),
      ),
    );
  }
}

class StoryViewer extends StatefulWidget {
  const StoryViewer({
    super.key,
    required this.stories,
    required this.initialProfile,
  });

  final List<Map<String, dynamic>> stories;
  final Map<String, dynamic> initialProfile;

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  VideoPlayerController? _video;
  int _index = 0;
  bool _paused = false;
  bool _videoReady = false;

  Map<String, dynamic> get _story => widget.stories[_index];
  String get _url => (_story['resolved_url'] ?? '').toString();
  bool get _isVideo => _story['media_type'] == 'video';
  @override
  void initState() {
    super.initState();
    _progress =
        AnimationController(vsync: this, duration: const Duration(seconds: 5))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && mounted) _next();
          });
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    _progress.stop();
    _progress.value = 0;
    final previous = _video;
    _video = null;
    _videoReady = false;
    if (previous != null) {
      await previous.pause();
      await previous.dispose();
    }
    if (!mounted) return;

    if (_url.isEmpty) {
      _progress.duration = const Duration(seconds: 5);
      _progress.forward();
      setState(() {});
      return;
    }

    if (_isVideo) {
      final controller = VideoPlayerController.networkUrl(Uri.parse(_url));
      _video = controller;
      try {
        await controller.initialize();
        if (!mounted || _video != controller) return;
        _videoReady = true;
        _progress.duration = controller.value.duration;
        controller.addListener(_onVideoTick);
        if (!_paused) await controller.play();
      } catch (_) {
        _videoReady = false;
      }
    }
    if (!mounted) return;
    if (!_isVideo || !_videoReady) {
      _progress.duration = const Duration(seconds: 5);
    }
    if (!_paused) _progress.forward();
    setState(() {});
  }

  void _onVideoTick() {
    final controller = _video;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.position >= controller.value.duration &&
        controller.value.duration > Duration.zero) {
      _next();
    }
  }

  Future<void> _pause() async {
    if (_paused) return;
    _paused = true;
    _progress.stop();
    await _video?.pause();
    if (mounted) setState(() {});
  }

  Future<void> _resume() async {
    if (!_paused) return;
    _paused = false;
    if (_videoReady) await _video?.play();
    _progress.forward();
    if (mounted) setState(() {});
  }

  void _next() {
    if (_index + 1 >= widget.stories.length) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _index++);
    _loadCurrent();
  }

  void _previous() {
    if (_progress.value > .12) {
      _progress.value = 0;
      if (_videoReady) {
        _video?.seekTo(Duration.zero);
        if (!_paused) _video?.play();
      } else if (!_paused) {
        _progress.forward();
      }
      return;
    }
    if (_index > 0) {
      setState(() => _index--);
      _loadCurrent();
    } else {
      _progress.value = 0;
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = Map<String, dynamic>.from(
      _story['profiles'] as Map? ?? widget.initialProfile,
    );
    final avatar = (user['avatar_url'] ?? '').toString();
    final url = _url;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (_) => _pause(),
          onLongPressEnd: (_) => _resume(),
          onTapUp: (details) {
            final width = MediaQuery.of(context).size.width;
            if (details.localPosition.dx < width * .35) {
              _previous();
            } else if (details.localPosition.dx > width * .65) {
              _next();
            } else if (_paused) {
              _resume();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: _isVideo
                    ? (_videoReady && _video != null
                          ? AspectRatio(
                              aspectRatio: _video!.value.aspectRatio > 0
                                  ? _video!.value.aspectRatio
                                  : 9 / 16,
                              child: VideoPlayer(_video!),
                            )
                          : const CircularProgressIndicator(
                              color: Colors.white,
                            ))
                    : (url.startsWith('http')
                          ? Image.network(
                              url,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => const Icon(
                                Icons.broken_image_outlined,
                                color: Colors.white,
                                size: 52,
                              ),
                            )
                          : const Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white,
                              size: 52,
                            )),
              ),
              Positioned(
                top: 8,
                left: 10,
                right: 10,
                child: Row(
                  children: List.generate(widget.stories.length, (i) {
                    return Expanded(
                      child: Container(
                        height: 3,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: i < _index
                                ? 1
                                : i == _index
                                ? _progress.value
                                : 0,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              Positioned(
                top: 22,
                left: 12,
                right: 8,
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 17,
                      backgroundImage: avatar.startsWith('http')
                          ? NetworkImage(avatar)
                          : null,
                      child: avatar.startsWith('http')
                          ? null
                          : const Icon(Icons.person, size: 18),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        (user['display_name'] ??
                                user['username'] ??
                                'Twice user')
                            .toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
              if ((_story['caption'] ?? '').toString().trim().isNotEmpty)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 32,
                  child: Text(
                    _story['caption'].toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                    ),
                  ),
                ),
              if (_paused)
                const Center(
                  child: Icon(
                    Icons.pause_circle_filled,
                    color: Colors.white70,
                    size: 60,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class FeedPage extends StatelessWidget {
  const FeedPage({
    super.key,
    required this.storyStripKey,
    required this.profile,
    required this.stories,
    required this.onCreateStory,
    required this.posts,
    required this.onLike,
    required this.onRefresh,
    required this.onCommentChanged,
    required this.onOpenComposer,
  });

  final GlobalKey<StoryStripState> storyStripKey;
  final Map<String, dynamic> profile;
  final List<Map<String, dynamic>> stories;
  final Future<void> Function(AssetEntity asset, String caption) onCreateStory;
  final List<SocialPost> posts;
  final ValueChanged<SocialPost> onLike;
  final Future<void> Function() onRefresh;
  final VoidCallback onCommentChanged;
  final VoidCallback onOpenComposer;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
      children: [
        StoryStrip(
          key: storyStripKey,
          onCreateStory: onCreateStory,
          profile: profile,
          stories: stories,
        ),
        const SizedBox(height: 5),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(17),
            child: InkWell(
              onTap: onOpenComposer,
              borderRadius: BorderRadius.circular(17),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: const Color(0xFFECE7FF),
                      child: const Icon(
                        Icons.person_rounded,
                        color: violet,
                        size: 27,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2F3F5),
                          borderRadius: BorderRadius.circular(25),
                        ),
                        child: const Text(
                          "What's on your mind?",
                          style: TextStyle(
                            color: Color(0xFF65676B),
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Icon(
                      Icons.photo_library_outlined,
                      color: Color(0xFF45BD62),
                      size: 25,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (posts.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 70),
            child: Column(
              children: [
                Icon(Icons.dynamic_feed_outlined, size: 56, color: muted),
                SizedBox(height: 14),
                Text(
                  'No posts yet',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
                ),
                SizedBox(height: 7),
                Text(
                  'Follow people or share your first moment.',
                  style: TextStyle(color: muted),
                ),
              ],
            ),
          )
        else
          ...posts.map(
            (post) => PostCard(
              post: post,
              onLike: onLike,
              onCommentChanged: onCommentChanged,
            ),
          ),
      ],
    ),
  );
}

class _AnimatedLikeButton extends StatefulWidget {
  const _AnimatedLikeButton({required this.liked, required this.onPressed});

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
      tween: Tween(
        begin: 1.0,
        end: 1.35,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.35,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeInOut)),
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

class _PostMediaItem extends StatefulWidget {
  const _PostMediaItem({required this.media});

  final Map<String, dynamic> media;

  @override
  State<_PostMediaItem> createState() => _PostMediaItemState();
}

class _PostMediaItemState extends State<_PostMediaItem> {
  VideoPlayerController? _controller;
  bool _failed = false;
  bool _userPaused = false;
  bool _showVideoControls = true;
  double _visibleFraction = 0;
  Timer? _controlsTimer;

  bool get _isVideo =>
      (widget.media['media_type'] ?? '').toString().toLowerCase() == 'video';

  String get _url => (widget.media['resolved_url'] ?? '').toString().trim();

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    if (!_isVideo || _url.isEmpty) {
      if (_isVideo && mounted) setState(() => _failed = true);
      return;
    }

    final controller = VideoPlayerController.networkUrl(Uri.parse(_url));
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(1);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {});
      _syncPlayback(controller);
      if (controller.value.isPlaying) {
        _showControlsTemporarily();
      }
    } catch (_) {
      await controller.dispose();
      if (identical(_controller, controller)) _controller = null;
      if (mounted) setState(() => _failed = true);
    }
  }

  void _showControlsTemporarily() {
    if (!mounted) return;
    setState(() => _showVideoControls = true);
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showVideoControls = false);
    });
  }

  void _syncPlayback(VideoPlayerController controller) {
    if (!mounted || !controller.value.isInitialized) return;
    if (_visibleFraction >= 0.6 && !_userPaused) {
      if (!controller.value.isPlaying) {
        controller.play();
        _showControlsTemporarily();
      }
    } else {
      if (controller.value.isPlaying) controller.pause();
    }
  }

  @override
  void didUpdateWidget(covariant _PostMediaItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media['resolved_url'] != widget.media['resolved_url'] ||
        oldWidget.media['media_type'] != widget.media['media_type']) {
      final old = _controller;
      _controller = null;
      _failed = false;
      _userPaused = false;
      _visibleFraction = 0;
      old?.dispose();
      _initializeVideo();
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _controller?.pause();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;

    if (!_isVideo) {
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
    }

    final controller = _controller;
    if (_failed) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Icon(Icons.error_outline, color: Colors.white, size: 42),
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _showControlsTemporarily,
      child: VisibilityDetector(
        key: ValueKey('twice-video-$url'),
        onVisibilityChanged: (info) {
          _visibleFraction = info.visibleFraction;
          _syncPlayback(controller);
        },
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: controller.value.size.width,
                  height: controller.value.size.height,
                  child: VideoPlayer(controller),
                ),
              ),
              if (_showVideoControls)
                Center(
                  child: Material(
                    color: const Color(0x99000000),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: controller.value.isPlaying
                          ? 'Pause video'
                          : 'Play video',
                      onPressed: () {
                        if (controller.value.isPlaying) {
                          _userPaused = true;
                          controller.pause();
                        } else {
                          _userPaused = false;
                          _syncPlayback(controller);
                        }
                        _showControlsTemporarily();
                      },
                      icon: Icon(
                        controller.value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 42,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
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
                SizedBox(
                  width: 44,
                  height: 44,
                  child: ClipOval(
                    child: (post.avatarUrl ?? '').trim().isEmpty
                        ? const ColoredBox(
                            color: Color(0xFFF0F2F5),
                            child: Icon(
                              Icons.person_outline_rounded,
                              color: muted,
                            ),
                          )
                        : Image.network(
                            post.avatarUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const ColoredBox(
                              color: Color(0xFFF0F2F5),
                              child: Icon(
                                Icons.person_outline_rounded,
                                color: muted,
                              ),
                            ),
                          ),
                  ),
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
                          content: Text(
                            'Use your device share options to share this post.',
                          ),
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
                style: const TextStyle(color: ink, fontSize: 14, height: 1.4),
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
                      return _PostMediaItem(media: media[index]);
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
                          useSafeArea: true,
                          backgroundColor: Colors.transparent,
                          barrierColor: Colors.black54,
                          enableDrag: true,
                          showDragHandle: false,
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(24),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
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
                      onPressed: () {
                        final wasSaved = post.saved;
                        final uid =
                            Supabase.instance.client.auth.currentUser?.id;
                        if (uid == null) return;

                        final rows = List<Map<String, dynamic>>.from(
                          (post.data['saved_posts'] as List? ?? const [])
                              .whereType<Map>()
                              .map((row) => Map<String, dynamic>.from(row)),
                        );

                        // Update the bookmark immediately.
                        if (wasSaved) {
                          rows.removeWhere((row) => row['user_id'] == uid);
                        } else {
                          rows.add({'user_id': uid});
                        }
                        post.data['saved_posts'] = rows;
                        onCommentChanged();

                        // Persist asynchronously; do not reload the feed.
                        SocialRepository.instance
                            .toggleSaved(post.id, wasSaved)
                            .catchError((Object e) {
                              if (!context.mounted) return;
                              // Roll back only this bookmark state.
                              final current = List<Map<String, dynamic>>.from(
                                (post.data['saved_posts'] as List? ?? const [])
                                    .whereType<Map>()
                                    .map(
                                      (row) => Map<String, dynamic>.from(row),
                                    ),
                              );
                              current.removeWhere(
                                (row) => row['user_id'] == uid,
                              );
                              if (wasSaved) current.add({'user_id': uid});
                              post.data['saved_posts'] = current;
                              onCommentChanged();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Save failed: $e')),
                              );
                            });
                      },
                      icon: Icon(
                        post.saved
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        size: 26,
                        color: post.saved ? const Color(0xFFE2B900) : ink,
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
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Allow photo access to select media.')),
        );
      }
      return;
    }
    final imagePaths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    final videoPaths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      onlyAll: true,
    );

    final List<AssetEntity> assets = [];
    if (imagePaths.isNotEmpty) {
      assets.addAll(
        await imagePaths.first.getAssetListPaged(page: 0, size: 100),
      );
    }
    if (videoPaths.isNotEmpty) {
      assets.addAll(
        await videoPaths.first.getAssetListPaged(page: 0, size: 100),
      );
    }
    assets.sort(
      (a, b) => (b.createDateSecond ?? 0).compareTo(a.createDateSecond ?? 0),
    );
    if (!mounted || assets.isEmpty) return;
    final picked = await showModalBottomSheet<List<AssetEntity>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _MediaPicker(assets: assets),
    );
    if (picked != null) {
      setState(() {
        selectedMedia
          ..clear()
          ..addAll(picked.take(10));
      });
    }
  }

  Future<void> _publish() async {
    if (publishing) return;
    setState(() => publishing = true);
    try {
      await widget.onPost(controller.text, selectedMedia);
      controller.clear();
      setState(() => selectedMedia.clear());
    } catch (_) {
    } finally {
      if (mounted) setState(() => publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    appBar: AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        tooltip: 'Close',
        onPressed: () => Navigator.of(context).maybePop(),
        icon: const Icon(Icons.close, color: Colors.black, size: 28),
      ),
      title: const Text(
        'Create post',
        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Center(
            child: FilledButton(
              onPressed: publishing ? null : _publish,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1877F2),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              child: Text(publishing ? 'Posting…' : 'Post'),
            ),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 25,
                      backgroundColor: const Color(0xFFE8F0FE),
                      child: const Icon(
                        Icons.person,
                        color: Color(0xFF1877F2),
                        size: 29,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your profile',
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F2F5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.public, size: 14),
                              SizedBox(width: 5),
                              Text(
                                'Public',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                              SizedBox(width: 5),
                              Icon(Icons.arrow_drop_down, size: 17),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 5,
                  maxLines: null,
                  maxLength: 5000,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 23,
                    height: 1.35,
                  ),
                  decoration: const InputDecoration(
                    hintText: "What's on your mind?",
                    hintStyle: TextStyle(
                      color: Color(0xFF8A8D91),
                      fontSize: 23,
                    ),
                    border: InputBorder.none,
                    counterStyle: TextStyle(color: Colors.grey),
                  ),
                ),
                if (selectedMedia.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: selectedMedia.map((asset) {
                      return Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: FutureBuilder<Uint8List?>(
                              future: asset.thumbnailDataWithSize(
                                const ThumbnailSize(360, 360),
                              ),
                              builder: (_, snapshot) {
                                if (snapshot.data == null) {
                                  return Container(
                                    width: 108,
                                    height: 108,
                                    color: const Color(0xFFF0F2F5),
                                    child: const Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  );
                                }
                                return Image.memory(
                                  snapshot.data!,
                                  width: 108,
                                  height: 108,
                                  fit: BoxFit.cover,
                                );
                              },
                            ),
                          ),
                          if (asset.type == AssetType.video)
                            const Positioned(
                              left: 8,
                              bottom: 8,
                              child: Icon(
                                Icons.play_circle_fill,
                                color: Colors.white,
                                size: 25,
                              ),
                            ),
                          Positioned(
                            right: 4,
                            top: 4,
                            child: InkWell(
                              onTap: () =>
                                  setState(() => selectedMedia.remove(asset)),
                              child: const CircleAvatar(
                                radius: 13,
                                backgroundColor: Colors.black54,
                                child: Icon(
                                  Icons.close,
                                  color: Colors.white,
                                  size: 17,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFFE0E0E0)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Add to your post',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add photos or videos',
                    onPressed: _pick,
                    icon: const Icon(
                      Icons.photo_library_outlined,
                      color: Color(0xFF45BD62),
                      size: 27,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add more media',
                    onPressed: _pick,
                    icon: const Icon(
                      Icons.video_library_outlined,
                      color: Color(0xFF1877F2),
                      size: 27,
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

class _MediaPicker extends StatefulWidget {
  const _MediaPicker({required this.assets});
  final List<AssetEntity> assets;
  @override
  State<_MediaPicker> createState() => _MediaPickerState();
}

class _MediaPickerState extends State<_MediaPicker> {
  final Set<AssetEntity> chosen = {};
  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .78,
    child: Column(
      children: [
        ListTile(
          title: const Text(
            'Select media',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          trailing: TextButton(
            onPressed: () => Navigator.pop(context, chosen.toList()),
            child: const Text('Done'),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 3,
              mainAxisSpacing: 3,
            ),
            itemCount: widget.assets.length,
            itemBuilder: (_, i) {
              final a = widget.assets[i];
              return InkWell(
                onTap: () => setState(() {
                  if (chosen.contains(a)) {
                    chosen.remove(a);
                  } else if (chosen.length < 10) {
                    chosen.add(a);
                  }
                }),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FutureBuilder<Uint8List?>(
                      future: a.thumbnailDataWithSize(
                        const ThumbnailSize(220, 220),
                      ),
                      builder: (_, s) => s.data == null
                          ? const ColoredBox(color: canvas)
                          : Image.memory(s.data!, fit: BoxFit.cover),
                    ),
                    if (a.type == AssetType.video)
                      const Align(
                        alignment: Alignment.bottomRight,
                        child: Icon(
                          Icons.play_circle_fill,
                          color: Colors.white,
                        ),
                      ),
                    if (chosen.contains(a))
                      const Align(
                        alignment: Alignment.topRight,
                        child: Icon(Icons.check_circle, color: violet),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final controller = TextEditingController();
  List<Map<String, dynamic>> results = [];
  bool busy = false;
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() {
        results = [];
        error = null;
      });
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await SocialRepository.instance.search(q);
      if (mounted) setState(() => results = data);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: controller,
          onChanged: _search,
          decoration: InputDecoration(
            hintText: 'Search people by name or @username',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              onPressed: () {
                controller.clear();
                _search('');
              },
              icon: const Icon(Icons.close),
            ),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(error!, style: const TextStyle(color: Colors.red)),
        ),
      Expanded(
        child: results.isEmpty
            ? Center(
                child: Text(
                  controller.text.isEmpty
                      ? 'Search for real Twice users'
                      : 'No users found',
                  style: const TextStyle(color: muted),
                ),
              )
            : ListView.builder(
                itemCount: results.length,
                itemBuilder: (_, i) => _UserTile(user: results[i]),
              ),
      ),
    ],
  );
}

class _UserTile extends StatefulWidget {
  const _UserTile({required this.user});
  final Map<String, dynamic> user;
  @override
  State<_UserTile> createState() => _UserTileState();
}

class _UserTileState extends State<_UserTile> {
  bool following = false, busy = false;
  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    if (user['result_type'] == 'post') {
      final author = user['profiles'] as Map? ?? {};
      return ListTile(
        leading: const CircleAvatar(child: Icon(Icons.article_outlined)),
        title: Text(
          (user['caption'] ?? 'Media post').toString(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${author['display_name'] ?? author['username'] ?? 'Twice user'} · @${author['username'] ?? 'user'}',
        ),
      );
    }
    final isSelf = user['id'] == Supabase.instance.client.auth.currentUser?.id;
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: user['avatar_url'] == null
            ? null
            : NetworkImage(user['avatar_url'].toString()),
        child: user['avatar_url'] == null ? const Icon(Icons.person) : null,
      ),
      title: Text(
        (user['display_name'] ?? user['username'] ?? 'Twice user').toString(),
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text('@${user['username'] ?? 'user'}'),
      trailing: isSelf
          ? null
          : Wrap(
              children: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            if (following) {
                              await SocialRepository.instance.unfollow(
                                user['id'].toString(),
                              );
                            } else {
                              await SocialRepository.instance.follow(
                                user['id'].toString(),
                                privateAccount: user['is_private'] == true,
                              );
                            }
                            if (mounted) setState(() => following = !following);
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                  content: Text('Follow action failed: $e'),
                                ),
                              );
                            }
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                  child: Text(
                    busy
                        ? '…'
                        : following
                        ? 'Following'
                        : 'Follow',
                  ),
                ),
                IconButton(
                  tooltip: 'Message',
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            final id = await SocialRepository.instance
                                .createConversation(user['id'].toString());
                            if (context.mounted) {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ConversationPage(
                                    id: id,
                                    title:
                                        (user['display_name'] ??
                                                user['username'] ??
                                                'Message')
                                            .toString(),
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Could not start conversation: $e',
                                  ),
                                ),
                              );
                            }
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                  icon: const Icon(Icons.send_outlined),
                ),
              ],
            ),
    );
  }
}

class CommentsSheet extends StatefulWidget {
  const CommentsSheet({super.key, required this.post});
  final SocialPost post;
  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final controller = TextEditingController();
  List<Map<String, dynamic>> rows = [];
  bool busy = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  String? loadError;
  bool sending = false;

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        busy = true;
        loadError = null;
      });
    }
    try {
      final data = await SocialRepository.instance.comments(widget.post.id);
      if (mounted) {
        setState(() {
          rows = data;
          busy = false;
          loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          loadError = e.toString();
        });
      }
    }
  }

  Future<void> _send() async {
    if (sending) return;
    final text = controller.text.trim();
    if (text.isEmpty) return;

    FocusScope.of(context).unfocus();

    final optimistic = <String, dynamic>{
      'id': 'local_${DateTime.now().microsecondsSinceEpoch}',
      'post_id': widget.post.id,
      'user_id': Supabase.instance.client.auth.currentUser?.id ?? '',
      'body': text,
      'created_at': DateTime.now().toIso8601String(),
      'profiles': <String, dynamic>{'display_name': 'You'},
      '_pending': true,
    };

    // Render immediately and clear the composer before network work begins.
    setState(() {
      rows = [...rows, optimistic];
      controller.clear();
      loadError = null;
      busy = false;
      sending = false;
    });

    // Persist in the background; no comments refresh or feed reload.
    try {
      await SocialRepository.instance.addComment(widget.post.id, text);
      if (!mounted) return;
      setState(() {
        optimistic.remove('_pending');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        optimistic['_failed'] = true;
        optimistic.remove('_pending');
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Comment is visible but could not sync: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    height: MediaQuery.sizeOf(context).height * .78,
    decoration: const BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    child: Column(
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
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Comments',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: busy
              ? const Center(child: CircularProgressIndicator())
              : loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Could not load comments'),
                        const SizedBox(height: 8),
                        Text(loadError!, textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : rows.isEmpty
              ? const Center(child: Text('No comments yet'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final p = r['profiles'] as Map? ?? {};
                    final name = (p['display_name'] ?? p['username'] ?? 'User')
                        .toString();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 17,
                            backgroundColor: const Color(0xFFEDE7FF),
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : 'U',
                              style: const TextStyle(
                                color: violet,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3F3F6),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text((r['body'] ?? '').toString()),
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
        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              14,
              8,
              14,
              10 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F3F6),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: const Color(0xFFE5E3EC)),
                    ),
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Write a comment…',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: violet,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: sending ? null : _send,
                    child: SizedBox(
                      width: 46,
                      height: 46,
                      child: Center(
                        child: sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.send_rounded,
                                color: Colors.white,
                                size: 21,
                              ),
                      ),
                    ),
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
                  child: Text(
                    'No activity yet',
                    style: TextStyle(color: muted),
                  ),
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

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({
    super.key,
    required this.profile,
    required this.onSaved,
  });

  final Map<String, dynamic> profile;
  final Future<void> Function() onSaved;

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController display;
  late final TextEditingController username;
  late final TextEditingController bio;
  AssetEntity? photo;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    display = TextEditingController(
      text: (widget.profile['display_name'] ?? '').toString(),
    );
    username = TextEditingController(
      text: (widget.profile['username'] ?? '').toString(),
    );
    bio = TextEditingController(text: (widget.profile['bio'] ?? '').toString());
  }

  @override
  void dispose() {
    display.dispose();
    username.dispose();
    bio.dispose();
    super.dispose();
  }

  Future<void> _choosePhoto() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth && !permission.hasAccess) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Allow photo access to continue.')),
        );
      }
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: true,
    );
    if (paths.isEmpty) return;
    final assets = await paths.first.getAssetListPaged(page: 0, size: 100);
    if (!mounted) return;
    final photos = assets
        .where((a) => a.type == AssetType.image || a.type == AssetType.video)
        .toList();
    final picked = await showModalBottomSheet<List<AssetEntity>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MediaPicker(assets: photos),
    );
    if (picked != null && picked.isNotEmpty && mounted) {
      setState(() => photo = picked.first);
    }
  }

  Future<void> _save() async {
    if (saving) return;
    if (display.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a display name.')));
      return;
    }
    setState(() => saving = true);
    try {
      await SocialRepository.instance.updateProfile(
        displayName: display.text,
        username: username.text,
        bio: bio.text,
        avatarAsset: photo,
      );
      await widget.onSaved();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated successfully')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save profile: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  InputDecoration _decoration(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon, color: violet),
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Color(0xFFE8E8F0)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Color(0xFFE8E8F0)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: violet, width: 1.5),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final avatar = (widget.profile['avatar_url'] ?? '').toString();
    return Scaffold(
      backgroundColor: canvas,
      appBar: AppBar(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          tooltip: 'Back',
          onPressed: saving ? null : () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: const Text(
          'Edit Profile',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
                children: [
                  Center(
                    child: Column(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                border: Border.all(
                                  color: const Color(0xFFE5DFFF),
                                  width: 2,
                                ),
                              ),
                              child: ClipOval(
                                child: SizedBox(
                                  width: 112,
                                  height: 112,
                                  child: photo != null
                                      ? FutureBuilder<Uint8List?>(
                                          future: photo!.thumbnailDataWithSize(
                                            const ThumbnailSize(360, 360),
                                          ),
                                          builder: (_, snap) =>
                                              snap.data == null
                                              ? const Center(
                                                  child:
                                                      CircularProgressIndicator(),
                                                )
                                              : Image.memory(
                                                  snap.data!,
                                                  fit: BoxFit.cover,
                                                ),
                                        )
                                      : avatar.isNotEmpty
                                      ? Image.network(
                                          avatar,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => const Icon(
                                            Icons.person_rounded,
                                            size: 54,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.person_rounded,
                                          size: 54,
                                          color: muted,
                                        ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Material(
                                color: violet,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: _choosePhoto,
                                  child: const Padding(
                                    padding: EdgeInsets.all(10),
                                    child: Icon(
                                      Icons.add_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: _choosePhoto,
                          icon: const Icon(Icons.photo_outlined),
                          label: const Text('Change profile photo'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: display,
                    textCapitalization: TextCapitalization.words,
                    maxLength: 60,
                    decoration: _decoration(
                      'Display name',
                      Icons.person_outline_rounded,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: username,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.none,
                    decoration: _decoration(
                      '@Username',
                      Icons.alternate_email_rounded,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: bio,
                    maxLines: 4,
                    maxLength: 160,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: _decoration('Bio', Icons.notes_rounded),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFECECF2))),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: violet,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Save Changes',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FollowListPage extends StatefulWidget {
  const FollowListPage({
    super.key,
    required this.profileId,
    required this.followers,
  });

  final String profileId;
  final bool followers;

  @override
  State<FollowListPage> createState() => _FollowListPageState();
}

class _FollowListPageState extends State<FollowListPage> {
  List<Map<String, dynamic>> users = [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final result = await SocialRepository.instance.followProfiles(
        profileId: widget.profileId,
        followers: widget.followers,
      );
      if (!mounted) return;
      setState(() {
        users = result;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.followers ? 'Followers' : 'Following';
    return Scaffold(
      backgroundColor: canvas,
      appBar: AppBar(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator(color: violet))
            : error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cloud_off_rounded,
                        size: 42,
                        color: muted,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Could not load users',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: muted),
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              )
            : users.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: const BoxDecoration(
                        color: Color(0xFFEDE9FF),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.people_outline_rounded,
                        size: 36,
                        color: violet,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      widget.followers
                          ? 'No followers yet'
                          : 'Not following anyone yet',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'People will appear here when available.',
                      style: TextStyle(color: muted),
                    ),
                  ],
                ),
              )
            : RefreshIndicator(
                color: violet,
                onRefresh: _load,
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: users.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, index) {
                    final user = users[index];
                    final name = (user['display_name'] ?? '').toString().trim();
                    final username = (user['username'] ?? '').toString().trim();
                    final avatar = (user['avatar_url'] ?? '').toString().trim();
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFECECF2)),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 27,
                            backgroundColor: const Color(0xFFEDE9FF),
                            backgroundImage: avatar.isNotEmpty
                                ? NetworkImage(avatar)
                                : null,
                            child: avatar.isEmpty
                                ? const Icon(
                                    Icons.person_rounded,
                                    color: violet,
                                    size: 28,
                                  )
                                : null,
                          ),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name.isEmpty ? username : name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  username.isEmpty ? '@user' : '@$username',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _ProfilePageState extends State<ProfilePage> {
  bool _accountMenuOpen = false;

  int selectedTab = 0;
  int followersCount = 0;
  int followingCount = 0;
  bool _countsLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFollowCounts();
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Log out of Twice?'),
        content: const Text(
          'You will be signed out of your account on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD92D20),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
      // TwiceAuthGate listens to onAuthStateChange and returns to sign-in.
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not log out. Please try again.')),
      );
    }
  }

  Widget _clickableFollowStat(String value, String label, bool followers) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _countsLoading
          ? null
          : () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FollowListPage(
                    profileId: (widget.profile['id'] ?? '').toString(),
                    followers: followers,
                  ),
                ),
              );
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(
                color: muted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
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
        db
            .from('follows')
            .select('follower_id')
            .eq('following_id', id)
            .eq('status', 'accepted'),
        db
            .from('follows')
            .select('following_id')
            .eq('follower_id', id)
            .eq('status', 'accepted'),
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
      .where(
        (p) =>
            p.data['user_id'] == Supabase.instance.client.auth.currentUser?.id,
      )
      .toList();

  List<SocialPost> get _visiblePosts {
    if (selectedTab == 1) {
      return _myPosts
          .where(
            (p) => p.media.any(
              (m) =>
                  (m['media_type'] ?? '').toString().toLowerCase() == 'image',
            ),
          )
          .toList();
    }
    if (selectedTab == 2) {
      return _myPosts
          .where(
            (p) => p.media.any(
              (m) =>
                  (m['media_type'] ?? '').toString().toLowerCase() == 'video',
            ),
          )
          .toList();
    }
    return _myPosts;
  }

  Future<void> _edit() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditProfilePage(
          profile: Map<String, dynamic>.from(widget.profile),
          onSaved: widget.onRefresh,
        ),
      ),
    );
  }

  Future<void> _shareProfile() async {
    final username = (widget.profile['username'] ?? '').toString().trim();
    if (username.isEmpty || !mounted) return;

    final profileUrl = 'https://twice.app/@$username';
    final avatarUrl = (widget.profile['avatar_url'] ?? '').toString().trim();
    final displayName = (widget.profile['display_name'] ?? '')
        .toString()
        .trim();
    final brightness = ScreenBrightness();

    try {
      await brightness.setApplicationScreenBrightness(1.0);
      if (!mounted) {
        await brightness.resetApplicationScreenBrightness();
        return;
      }

      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          backgroundColor: Colors.white,
          elevation: 18,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(32),
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFEAE7FF),
                        width: 3,
                      ),
                    ),
                    child: CircleAvatar(
                      backgroundColor: const Color(0xFFF0F2F5),
                      backgroundImage: avatarUrl.isNotEmpty
                          ? NetworkImage(avatarUrl)
                          : null,
                      child: avatarUrl.isEmpty
                          ? const Icon(Icons.person_rounded, size: 38)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    displayName.isNotEmpty ? displayName : '@$username',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '@$username',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted, fontSize: 14),
                  ),
                  const SizedBox(height: 22),
                  Center(
                    child: Container(
                      width: 292,
                      height: 292,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: const Color(0xFFECEAF5)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x12000000),
                            blurRadius: 22,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: QrImageView(
                        data: profileUrl,
                        version: QrVersions.auto,
                        size: 272,
                        backgroundColor: Colors.white,
                        errorCorrectionLevel: QrErrorCorrectLevel.H,
                        embeddedImage: avatarUrl.isNotEmpty
                            ? NetworkImage(avatarUrl)
                            : null,
                        embeddedImageStyle: const QrEmbeddedImageStyle(
                          size: Size(58, 58),
                        ),
                        embeddedImageEmitsError: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.qr_code_scanner_rounded,
                        size: 18,
                        color: violet,
                      ),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Scan to find this profile on Twice',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: muted,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: violet,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(17),
                        ),
                      ),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: profileUrl),
                        );
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Profile link copied'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text(
                        'Copy profile link',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      await brightness.resetApplicationScreenBrightness();
    }
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
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          username.isEmpty ? 'Your profile' : '@$username',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Material(
                        color: _accountMenuOpen
                            ? const Color(0xFFEDE9FF)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => setState(
                            () => _accountMenuOpen = !_accountMenuOpen,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(7),
                            child: AnimatedRotation(
                              turns: _accountMenuOpen ? 0.5 : 0,
                              duration: const Duration(milliseconds: 220),
                              child: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 23,
                                color: violet,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
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
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeInOutCubic,
            child: _accountMenuOpen
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE8E7F0)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x0D171923),
                            blurRadius: 18,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            setState(() => _accountMenuOpen = false);
                            _logout();
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 13,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.logout_rounded,
                                  color: Color(0xFFD92D20),
                                  size: 21,
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Log out',
                                    style: TextStyle(
                                      color: Color(0xFFD92D20),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.arrow_forward_ios_rounded,
                                  size: 14,
                                  color: muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 86,
                  height: 86,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF0F2F5),
                    shape: BoxShape.circle,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: (profile['avatar_url'] ?? '').toString().trim().isEmpty
                      ? const Icon(Icons.person_outline_rounded, size: 43)
                      : Image.network(
                          profile['avatar_url'].toString(),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Center(
                            child: Icon(Icons.person_outline_rounded, size: 43),
                          ),
                        ),
                ),
                const SizedBox(width: 22),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _stat('${_myPosts.length}', 'Posts'),
                      _clickableFollowStat(
                        _countsLoading ? '…' : '$followersCount',
                        'Followers',
                        true,
                      ),
                      _clickableFollowStat(
                        _countsLoading ? '…' : '$followingCount',
                        'Following',
                        false,
                      ),
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
                if ((profile['display_name'] ?? '')
                    .toString()
                    .trim()
                    .isNotEmpty)
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
                  const Icon(
                    Icons.photo_library_outlined,
                    size: 43,
                    color: muted,
                  ),
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
                      await SocialRepository.instance.toggleLike(
                        item.id,
                        wasLiked,
                      );
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

class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});
  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  late Future<List<Map<String, dynamic>>> future;
  @override
  void initState() {
    super.initState();
    future = SocialRepository.instance.conversations();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Messages')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (_, s) {
        if (s.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (s.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text('Could not load conversations: ${s.error}'),
            ),
          );
        }
        final rows = s.data ?? [];
        if (rows.isEmpty) {
          return const Center(child: Text('No conversations yet'));
        }
        return ListView.builder(
          itemCount: rows.length,
          itemBuilder: (_, i) {
            final r = rows[i];
            final c = r['conversations'] as Map? ?? {};
            return ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text((c['title'] ?? 'Conversation').toString()),
              subtitle: const Text('Open conversation'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ConversationPage(
                    id: r['conversation_id'].toString(),
                    title: (c['title'] ?? 'Conversation').toString(),
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class ConversationPage extends StatefulWidget {
  const ConversationPage({super.key, required this.id, required this.title});
  final String id, title;
  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final controller = TextEditingController();
  late Future<List<Map<String, dynamic>>> future;
  @override
  void initState() {
    super.initState();
    future = SocialRepository.instance.messages(widget.id);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    try {
      await SocialRepository.instance.sendMessage(widget.id, controller.text);
      controller.clear();
      setState(() => future = SocialRepository.instance.messages(widget.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Message failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: Column(
      children: [
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: future,
            builder: (_, s) {
              if (s.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (s.hasError) {
                return Center(
                  child: Text('Could not load messages: ${s.error}'),
                );
              }
              final rows = s.data ?? [];
              return ListView.builder(
                reverse: false,
                padding: const EdgeInsets.all(12),
                itemCount: rows.length,
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final own =
                      r['sender_id'] ==
                      Supabase.instance.client.auth.currentUser?.id;
                  return Align(
                    alignment: own
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: own ? const Color(0xFFECE7FF) : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text((r['body'] ?? '').toString()),
                    ),
                  );
                },
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    decoration: const InputDecoration(hintText: 'Message…'),
                  ),
                ),
                IconButton(
                  onPressed: _send,
                  icon: const Icon(Icons.send, color: violet),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
