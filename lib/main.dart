import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import 'messages_page.dart' as messaging;

import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'data/social_repository.dart';
import 'data/inbox_controller.dart';
import 'data/local_cache.dart';
import 'data/twice_media.dart';
import 'ads/ad_config.dart';
import 'widgets/ig_icons.dart';
import 'ads/ad_manager.dart';
import 'ads/feed_entries.dart';
import 'ads/native_ad_card.dart';

part 'videos_screen.dart';

ImageProvider<Object> _twiceImageProvider(
  String source, {
  int maxDimension = 1080,
}) {
  final value = source.trim();
  if (value.startsWith('file://')) {
    return ResizeImage.resizeIfNeeded(
      maxDimension,
      null,
      FileImage(File.fromUri(Uri.parse(value))),
    );
  }
  if (value.startsWith('/')) {
    return ResizeImage.resizeIfNeeded(
      maxDimension,
      null,
      FileImage(File(value)),
    );
  }
  return TwiceNetworkImage(value, maxDimension: maxDimension);
}

ImageProvider<Object> _twiceAvatarProvider(String source) =>
    _twiceImageProvider(source, maxDimension: 256);

String _formatClock(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

// A usable image source is a network URL OR a saved local copy (file:// or a
// device path). Saved avatars become file:// after they are cached.
bool _isImageSource(String value) {
  final v = value.trim();
  return v.startsWith('http') || v.startsWith('file://') || v.startsWith('/');
}

String _newTwiceUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

// ---- Twice design system (Instagram dark theme) -------------------------
// Pure AMOLED black background, white text, #262626 surfaces/dividers,
// Instagram blue for actions and #FF3040 for likes.
const igBlack = Color(0xFF000000);
const igSurface = Color(0xFF121212);
const igElevated = Color(0xFF262626);
const igBorder = Color(0xFF262626);
const igBlue = Color(0xFF0095F6);
const igHashtagBlue = Color(0xFF3897F0);
const igRed = Color(0xFFFF3040);
const igSeenRing = Color(0xFF4D4D4D);
const igStoryGradient = LinearGradient(
  colors: [
    Color(0xFFFEDA75),
    Color(0xFFFA7E1E),
    Color(0xFFD62976),
    Color(0xFF962FBF),
    Color(0xFF4F5BD5),
  ],
  begin: Alignment.bottomLeft,
  end: Alignment.topRight,
);

// Legacy names kept so the rest of the app picks the new palette up.
const ink = Color(0xFFFFFFFF); // primary text / icons (white on black)
const muted = Color(0xFFA8A8A8); // secondary text
const violet = igBlue; // accent (was purple) -> Instagram blue
const canvas = igBlack; // page background

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabasePublishableKey =
    String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

bool get supabaseConfigured =>
    supabaseUrl.startsWith('https://') && supabasePublishableKey.isNotEmpty;

// True only after Supabase has initialized successfully. If configuration is
// missing or initialization fails, the app still starts and shows its setup
// screen instead of remaining on Android's Flutter splash screen.
bool supabaseReady = false;
String? supabaseStartupError;

// BOOTFIX: the first frame is drawn immediately. Supabase starts in the
// background and the gate swaps from the splash to the app when it is ready.
final ValueNotifier<bool> supabaseBootFinished = ValueNotifier<bool>(false);

Future<void>? _bootFuture;

Future<void> _bootSupabase({bool isRetry = false}) {
  if (_bootFuture != null && !isRetry) return _bootFuture!;
  final future = _bootSupabaseImpl();
  _bootFuture = future;
  return future;
}

Future<void> _bootSupabaseImpl() async {
  final watch = Stopwatch()..start();
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
      if (!supabaseReady) {
        await Supabase.initialize(
          url: supabaseUrl,
          publishableKey: supabasePublishableKey,
        ).timeout(const Duration(seconds: 15));
        supabaseReady = true;
        supabaseStartupError = null;
      }
    } catch (error, stackTrace) {
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
  debugPrint(
    'TWICE_BOOT supabase ready=$supabaseReady in ${watch.elapsedMilliseconds}ms',
  );
  supabaseBootFinished.value = true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle.light.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: igBlack,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  TwiceMedia.configure();
  unawaited(LocalCache.instance.prewarm());
  runApp(const TwiceApp());
  unawaited(TwiceAds.init());
  unawaited(_bootSupabase());
  unawaited(TwiceMedia.trimDiskCache());
  unawaited(LocalCache.instance.pruneOldCacheEntries());
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

ThemeData _twiceDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  const scheme = ColorScheme.dark(
    primary: igBlue,
    onPrimary: Colors.white,
    secondary: igBlue,
    onSecondary: Colors.white,
    surface: igBlack,
    onSurface: Colors.white,
    surfaceContainerLowest: igBlack,
    surfaceContainerLow: igBlack,
    surfaceContainer: igSurface,
    surfaceContainerHigh: igElevated,
    surfaceContainerHighest: igElevated,
    outline: Color(0xFF363636),
    outlineVariant: igBorder,
    error: igRed,
    onError: Colors.white,
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: igBlack,
    canvasColor: igBlack,
    cardColor: igBlack,
    dividerColor: igBorder,
    dividerTheme: const DividerThemeData(color: igBorder, thickness: 0.5),
    textTheme: base.textTheme.apply(
      fontFamily: 'Roboto',
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: 'Roboto',
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    iconTheme: const IconThemeData(color: Colors.white),
    appBarTheme: const AppBarTheme(
      backgroundColor: igBlack,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: igSurface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: igSurface,
      showDragHandle: false,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: igElevated,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: igElevated,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(color: Colors.white, fontSize: 14),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: igElevated,
      contentTextStyle: TextStyle(color: Colors.white),
      actionTextColor: igBlue,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: igElevated,
      hintStyle: const TextStyle(color: muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF363636)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: igBlue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: igBlue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: igBlue),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Color(0xFF363636)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Colors.white,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Colors.white,
      selectionColor: Color(0x660095F6),
      selectionHandleColor: igBlue,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: Colors.white,
      textColor: Colors.white,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? igBlue : igElevated,
      ),
    ),
  );
}

class TwiceApp extends StatelessWidget {
  const TwiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Twice',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: _twiceDarkTheme(),
      theme: _twiceDarkTheme(),
      home: const TwiceAuthGate(),
    );
  }
}

class TwiceAuthGate extends StatelessWidget {
  const TwiceAuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: supabaseBootFinished,
      builder: (context, finished, _) {
        if (!finished && supabaseConfigured) return const _TwiceSplash();
        if (!supabaseReady) {
          return TwiceSignInPage(
            configurationMissing: !supabaseConfigured,
            startupError: supabaseStartupError,
            onRetryStartup: supabaseConfigured
                ? () {
                    supabaseBootFinished.value = false;
                    _bootSupabase(isRetry: true);
                  }
                : null,
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
      },
    );
  }
}

class _TwiceSplash extends StatefulWidget {
  const _TwiceSplash();

  @override
  State<_TwiceSplash> createState() => _TwiceSplashState();
}

class _TwiceSplashState extends State<_TwiceSplash> {
  bool _slow = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: canvas,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _TwiceLogo(size: 58),
            const SizedBox(height: 18),
            AnimatedOpacity(
              opacity: _slow ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Still connecting… check your internet.',
                    style: TextStyle(color: muted, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () {
                      supabaseBootFinished.value = false;
                      _bootSupabase(isRetry: true);
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Retry Connection'),
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

/// Facebook-style placeholder shown instead of a spinner on a cold start
/// with no cached feed.
class _FeedSkeleton extends StatefulWidget {
  const _FeedSkeleton();

  @override
  State<_FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<_FeedSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final tone = Color.lerp(
          const Color(0xFF262626),
          const Color(0xFF262626),
          _pulse.value,
        )!;
        Widget box(double w, double h, {double r = 8}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: tone,
            borderRadius: BorderRadius.circular(r),
          ),
        );
        return ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
          children: [
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                itemCount: 6,
                separatorBuilder: (context, index) => const SizedBox(width: 12),
                itemBuilder: (context, index) => Column(
                  children: [
                    box(64, 64, r: 32),
                    const SizedBox(height: 8),
                    box(46, 10),
                  ],
                ),
              ),
            ),
            for (var i = 0; i < 3; i++)
              Container(
                margin: const EdgeInsets.fromLTRB(0, 12, 0, 0),
                color: igBlack,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(13),
                      child: Row(
                        children: [
                          box(44, 44, r: 22),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              box(130, 12),
                              const SizedBox(height: 7),
                              box(90, 10),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Container(height: 260, color: tone),
                    const SizedBox(height: 14),
                  ],
                ),
              ),
          ],
        );
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
        color: const Color(0xFF2B1013),
        border: Border.all(color: const Color(0xFF5C1D24)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFFFF6B6B),
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
    this.onRetryStartup,
  });

  final bool configurationMissing;
  final String? startupError;
  final VoidCallback? onRetryStartup;

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
                  const Center(child: _TwiceLogo(size: 58)),
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
                      fillColor: igElevated,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: Color(0xFF363636)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: Color(0xFF363636)),
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
                        fillColor: igElevated,
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
                  if (widget.configurationMissing || widget.startupError != null) ...[
                    const SizedBox(height: 18),
                    _ErrorPanel(
                      message: widget.startupError ?? 'Supabase configuration is missing. Check the GitHub Actions build secrets.',
                    ),
                    if (widget.onRetryStartup != null) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _loading ? null : widget.onRetryStartup,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Retry Connection'),
                      ),
                    ],
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
  int get commentCount {
    final raw = data['comments'];
    if (raw is List && raw.isNotEmpty && raw.first is Map) {
      return int.tryParse((raw.first as Map)['count'].toString()) ?? 0;
    }
    return 0;
  }

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

class _TwiceShellState extends State<TwiceShell> with WidgetsBindingObserver {
  final repo = SocialRepository.instance;
  int selected = 0;
  bool loading = true;
  String? error;
  Map<String, dynamic> profile = {};
  List<SocialPost> posts = [];
  List<Map<String, dynamic>> stories = [];
  final GlobalKey<StoryStripState> _storyStripKey =
      GlobalKey<StoryStripState>();

  DateTime? _lastResumeRefresh;
  bool _refreshingOnResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    InboxController.instance.start();
    _loadAll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;

    final now = DateTime.now();
    final previous = _lastResumeRefresh;
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 15)) {
      return;
    }

    _lastResumeRefresh = now;
    _refreshAfterResume();
  }

  Future<void> _refreshAfterResume() async {
    if (_refreshingOnResume || !mounted) return;
    _refreshingOnResume = true;

    try {
      await repo.syncPendingLikes();
      if (mounted) await _refreshQuietly();
    } catch (e) {
      debugPrint('Twice background refresh deferred: $e');
    } finally {
      _refreshingOnResume = false;
    }
  }

  Future<void> _refreshQuietly() async {
    if (!mounted) return;

    try {
      final values = await Future.wait<dynamic>([
        repo.myProfile(),
        repo.feed(),
        repo.loadStories(),
      ]);
      if (!mounted) return;

      final freshProfile = Map<String, dynamic>.from(values[0] as Map);
      final freshRows = values[1] as List<Map<String, dynamic>>;
      final freshStories = values[2] as List<Map<String, dynamic>>;

      void preserveAvatar(
        Map<String, dynamic> fresh,
        Map<String, dynamic> old,
      ) {
        final freshPath = fresh['avatar_object_path']?.toString() ?? '';
        final oldPath = old['avatar_object_path']?.toString() ?? '';
        if (freshPath.isNotEmpty && freshPath == oldPath) {
          fresh['avatar_url'] = old['avatar_url'];
        }
      }

      preserveAvatar(freshProfile, profile);

      final existingPosts = <String, SocialPost>{
        for (final post in posts) post.id: post,
      };
      final mergedPosts = <SocialPost>[];

      for (final raw in freshRows) {
        final incoming = Map<String, dynamic>.from(raw);
        final id = (incoming['id'] ?? '').toString();
        final existing = existingPosts[id];

        if (existing != null) {
          final oldData = existing.data;
          final oldAuthor = oldData['profiles'];
          final newAuthor = incoming['profiles'];

          if (oldAuthor is Map && newAuthor is Map) {
            final oldProfile = Map<String, dynamic>.from(oldAuthor);
            final newProfile = Map<String, dynamic>.from(newAuthor);
            preserveAvatar(newProfile, oldProfile);
            incoming['profiles'] = newProfile;
          }

          final oldMedia = oldData['media_resolved'];
          final newMedia = incoming['media_resolved'];

          if (oldMedia is List && newMedia is List) {
            for (final item in newMedia) {
              if (item is! Map) continue;
              final freshMedia = Map<String, dynamic>.from(item);
              final match = oldMedia
                  .whereType<Map>()
                  .where(
                    (old) =>
                        old['id'] == freshMedia['id'] &&
                        old['media_url'] == freshMedia['media_url'],
                  )
                  .firstOrNull;

              if (match != null) {
                // Preserve offline files, never reuse potentially expired
                // signed network URLs from the previous feed snapshot.
                final cachedMediaUrl = (match['resolved_url'] ?? '').toString();
                if (cachedMediaUrl.startsWith('file://')) {
                  freshMedia['resolved_url'] = cachedMediaUrl;
                }

                final cachedThumbnailUrl =
                    (match['resolved_thumbnail_url'] ?? '').toString();
                if (match['thumbnail_url'] == freshMedia['thumbnail_url'] &&
                    cachedThumbnailUrl.startsWith('file://')) {
                  freshMedia['resolved_thumbnail_url'] = cachedThumbnailUrl;
                }
              }

              final index = newMedia.indexOf(item);
              newMedia[index] = freshMedia;
            }
          }

          // Keep the SocialPost instance alive for this post ID.
          existing.data
            ..clear()
            ..addAll(incoming);
          mergedPosts.add(existing);
        } else {
          mergedPosts.add(SocialPost(incoming));
        }
      }

      final oldStoriesById = <String, Map<String, dynamic>>{
        for (final story in stories) (story['id'] ?? '').toString(): story,
      };
      final mergedStories = <Map<String, dynamic>>[];

      for (final raw in freshStories) {
        final fresh = Map<String, dynamic>.from(raw);
        final old = oldStoriesById[(fresh['id'] ?? '').toString()];

        if (old != null) {
          if (old['media_url'] == fresh['media_url']) {
            for (final key in ['resolved_url', 'resolved_thumbnail_url']) {
              final cachedUrl = (old[key] ?? '').toString();
              // Keep only local cached files; fresh network URLs must win.
              if (cachedUrl.startsWith('file://')) {
                fresh[key] = cachedUrl;
              }
            }
          }

          final oldAuthor = old['profiles'];
          final newAuthor = fresh['profiles'];
          if (oldAuthor is Map && newAuthor is Map) {
            final author = Map<String, dynamic>.from(newAuthor);
            preserveAvatar(author, Map<String, dynamic>.from(oldAuthor));
            fresh['profiles'] = author;
          }
        }
        mergedStories.add(fresh);
      }

      if (!mounted) return;
      setState(() {
        profile = freshProfile;
        posts = mergedPosts;
        stories = mergedStories;
        error = null;
      });
    } catch (e) {
      // A failed background refresh must not blank or interrupt the feed.
      debugPrint('Twice quiet refresh deferred: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    InboxController.instance.stop();
    super.dispose();
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

    // 1. Render durable local cache immediately (instant cold-start paint).
    try {
      final cached = await Future.wait<dynamic>([
        repo.cachedMyProfile(),
        repo.cachedFeed(),
        repo.cachedStories(),
      ]);
      if (!mounted) return;
      final cachedProfile = cached[0];
      final cachedPosts = cached[1] as List<Map<String, dynamic>>;
      final cachedStories = cached[2] as List<Map<String, dynamic>>;
      if (cachedProfile is Map ||
          cachedPosts.isNotEmpty ||
          cachedStories.isNotEmpty) {
        setState(() {
          if (cachedProfile is Map) {
            profile = Map<String, dynamic>.from(cachedProfile);
          }
          if (cachedPosts.isNotEmpty) {
            posts = cachedPosts.map(SocialPost.new).toList();
          }
          if (cachedStories.isNotEmpty) {
            stories = cachedStories;
          }
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      /* A cold install simply has an empty cache. */
    }

    if (posts.isEmpty && profile.isEmpty) {
      setState(() {
        loading = true;
        error = null;
      });
    }

    // 2. Fetch fresh data in the background and update smoothly.
    var anySuccess = false;
    Object? firstError;
    Future<void> run<T>(Future<T> work, void Function(T value) apply) async {
      try {
        final value = await work.timeout(const Duration(seconds: 25));
        if (!mounted) return;
        setState(() {
          apply(value);
          if (profile.isNotEmpty || posts.isNotEmpty) loading = false;
          error = null;
        });
        anySuccess = true;
      } catch (e) {
        firstError ??= e;
      }
    }

    await Future.wait<void>([
      run<Map<String, dynamic>>(
        repo.myProfile(),
        (value) => profile = Map<String, dynamic>.from(value),
      ),
      run<List<Map<String, dynamic>>>(
        repo.feed(),
        (value) => posts = value.map(SocialPost.new).toList(),
      ),
      run<List<Map<String, dynamic>>>(
        repo.loadStories(),
        (value) => stories = value,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      loading = false;
      error = anySuccess || posts.isNotEmpty || profile.isNotEmpty
          ? null
          : _friendlyError(firstError ?? 'Unable to load.');
    });
  }

  String _friendlyError(Object e) {
    final text = e.toString();
    final lower = text.toLowerCase();
    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('clientexception') ||
        lower.contains('connection reset') ||
        lower.contains('connection refused') ||
        lower.contains('connection aborted') ||
        lower.contains('connection closed') ||
        lower.contains('connection terminated') ||
        lower.contains('network is unreachable') ||
        lower.contains('handshakeexception') ||
        lower.contains('broken pipe') ||
        lower.contains('timed out') ||
        lower.contains('timeout')) {
      return 'Unable to reach the server right now. Check your connection and retry.';
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

  Future<void> _publish(
    String caption,
    List<AssetEntity> media,
    String visibility,
  ) async {
    try {
      await repo.publishPost(caption, media, visibility: visibility);
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
            CreatePage(onPost: _publish, profile: profile),
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
    // Tabs (Instagram order): Home, Search, Create (+), Reels, Profile.
    // Page index 3 is the notifications page, opened from the heart icon in
    // the top bar, so no tab is highlighted while it is open.
    final avatarUrl = (profile['avatar_url'] ?? '').toString();
    final avatarFallback =
        (profile['display_name'] ?? profile['username'] ?? 'U').toString();

    PreferredSizeWidget? appBar;
    if (selected == 0) {
      appBar = AppBar(
        toolbarHeight: 44,
        backgroundColor: igBlack,
        titleSpacing: 14,
        title: const _TwiceLogo(size: 30),
        actions: [
          _InboxHeartButton(onTap: () => setState(() => selected = 3)),
          IconButton(
            tooltip: 'Messages',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const messaging.MessagesPage(),
              ),
            ),
            icon: const Icon(Icons.send_outlined, size: 25),
          ),
          const SizedBox(width: 4),
        ],
      );
    } else if (selected == 3) {
      appBar = AppBar(
        toolbarHeight: 44,
        backgroundColor: igBlack,
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => setState(() => selected = 0),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        ),
        title: const Text(
          'Notifications',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
        ),
      );
    }

    return Scaffold(
      backgroundColor: igBlack,
      appBar: appBar,
      body: loading && profile.isEmpty
          ? const _FeedSkeleton()
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
                VideosPage(
                  active: selected == 2,
                  profile: profile,
                  onCreate: _openComposer,
                ),
                ActivityPage(active: selected == 3),
                ProfilePage(
                  profile: profile,
                  posts: posts,
                  onRefresh: _loadAll,
                ),
              ],
            ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: igBlack,
          border: Border(top: BorderSide(color: igBorder, width: 0.5)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 49,
            child: Row(
              children: [
                _IgTabButton(
                  label: 'Home',
                  active: selected == 0,
                  onTap: () => setState(() => selected = 0),
                  icon: const _SocialNavIcon(kind: _SocialNavKind.home),
                  activeIcon: const _SocialNavIcon(
                    kind: _SocialNavKind.home,
                    selected: true,
                  ),
                ),
                _IgTabButton(
                  label: 'Search',
                  active: selected == 1,
                  onTap: () => setState(() => selected = 1),
                  icon: const _SocialNavIcon(kind: _SocialNavKind.search),
                  activeIcon: const _SocialNavIcon(
                    kind: _SocialNavKind.search,
                    selected: true,
                  ),
                ),
                _IgTabButton(
                  label: 'Create',
                  active: false,
                  onTap: _openComposer,
                  icon: const _SocialNavIcon(kind: _SocialNavKind.plus),
                  activeIcon: const _SocialNavIcon(
                    kind: _SocialNavKind.plus,
                    selected: true,
                  ),
                ),
                _IgTabButton(
                  label: 'Reels',
                  active: selected == 2,
                  onTap: () => setState(() => selected = 2),
                  icon: const _SocialNavIcon(kind: _SocialNavKind.create),
                  activeIcon: const _SocialNavIcon(
                    kind: _SocialNavKind.create,
                    selected: true,
                  ),
                ),
                _IgTabButton(
                  label: 'Profile',
                  active: selected == 4,
                  onTap: () => setState(() => selected = 4),
                  icon: _ProfileNavAvatar(
                    url: avatarUrl,
                    fallback: avatarFallback,
                    selected: false,
                  ),
                  activeIcon: _ProfileNavAvatar(
                    url: avatarUrl,
                    fallback: avatarFallback,
                    selected: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Twice" script logo shown top-left on the home feed.
class _TwiceLogo extends StatelessWidget {
  const _TwiceLogo({this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context) => Text(
    'Twice',
    style: TextStyle(
      fontFamily: 'cursive',
      fontFamilyFallback: const ['Billabong', 'Dancing Script', 'serif'],
      fontStyle: FontStyle.italic,
      fontWeight: FontWeight.w700,
      fontSize: size,
      height: 1.1,
    ),
  );
}

/// Heart icon in the top bar. Opens notifications; red badge = unread count.
class _InboxHeartButton extends StatelessWidget {
  const _InboxHeartButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: InboxController.instance,
      builder: (context, _) {
        final count = InboxController.instance.unread;
        return IconButton(
          tooltip: 'Notifications',
          onPressed: onTap,
          icon: Badge(
            isLabelVisible: count > 0,
            label: Text(count > 99 ? '99+' : '$count'),
            backgroundColor: igRed,
            textColor: Colors.white,
            offset: const Offset(5, -5),
            child: const Icon(Icons.inbox_outlined, size: 27),
          ),
        );
      },
    );
  }
}

/// Bottom tab. Tapping squeezes the icon to 90% and springs it back
/// (100 ms elastic), like the Instagram tab bar.
class _IgTabButton extends StatefulWidget {
  const _IgTabButton({
    required this.label,
    required this.active,
    required this.onTap,
    required this.icon,
    required this.activeIcon,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final Widget icon;
  final Widget activeIcon;

  @override
  State<_IgTabButton> createState() => _IgTabButtonState();
}

class _IgTabButtonState extends State<_IgTabButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 0.9,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 0.9,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.elasticOut)),
      weight: 65,
    ),
  ]).animate(_press);

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      button: true,
      selected: widget.active,
      label: widget.label,
      child: InkResponse(
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        onTap: () {
          _press.forward(from: 0);
          widget.onTap();
        },
        child: Center(
          child: ScaleTransition(
            scale: _scale,
            child: widget.active ? widget.activeIcon : widget.icon,
          ),
        ),
      ),
    ),
  );
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
  final Set<String> _viewedStoryIds = <String>{};
  bool _viewedStoriesLoaded = false;

  String get _storyViewsCacheKey =>
      Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    _restoreViewedStories();
  }

  Future<void> _restoreViewedStories() async {
    final uid = _storyViewsCacheKey;
    if (uid.isEmpty) {
      if (mounted) setState(() => _viewedStoriesLoaded = true);
      return;
    }
    try {
      final saved = await LocalCache.instance.get(uid, 'viewed_stories');
      if (saved is List) {
        _viewedStoryIds.addAll(
          saved.map((value) => value.toString()).where((id) => id.isNotEmpty),
        );
      }
    } catch (e) {
      debugPrint('Could not restore viewed stories: $e');
    }
    if (mounted) setState(() => _viewedStoriesLoaded = true);
    unawaited(_syncViewedFromServer());
  }

  @override
  void didUpdateWidget(covariant StoryStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stories.length != widget.stories.length) {
      unawaited(_syncViewedFromServer());
    }
  }

  // The server remembers every story this account has opened, so the ring is
  // grey on all devices (and after a reinstall), like Instagram / Facebook.
  Future<void> _syncViewedFromServer() async {
    if (_storyViewsCacheKey.isEmpty || widget.stories.isEmpty) return;
    try {
      final ids = await SocialRepository.instance.myViewedStoryIds(
        widget.stories.map((s) => (s['id'] ?? '').toString()),
      );
      if (!mounted) return;
      final before = _viewedStoryIds.length;
      _viewedStoryIds.addAll(ids);
      if (_viewedStoryIds.length != before) {
        setState(() {});
        _persistViewed();
      }
    } catch (e) {
      debugPrint('Could not sync viewed stories: $e');
    }
  }

  void _persistViewed() {
    final uid = _storyViewsCacheKey;
    if (uid.isEmpty) return;
    LocalCache.instance
        .put(uid, 'viewed_stories', _viewedStoryIds.toList())
        .catchError((Object e) {
          debugPrint('Could not save viewed stories: $e');
        });
  }

  void _markStoryViewed(String storyId) {
    if (storyId.isEmpty || !_viewedStoryIds.add(storyId)) return;
    if (mounted) setState(() {});
    _persistViewed();
  }

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
                  'Choose a photo or video (videos up to 1 min)',
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
                    final tooLong =
                        item.type == AssetType.video && item.duration > 60;
                    return FutureBuilder<Uint8List?>(
                      future: item.thumbnailDataWithSize(
                        const ThumbnailSize(240, 240),
                      ),
                      builder: (context, snapshot) => InkWell(
                        onTap: tooLong
                            ? null
                            : () => Navigator.pop(sheetContext, item),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (snapshot.data != null)
                              Image.memory(snapshot.data!, fit: BoxFit.cover)
                            else
                              const ColoredBox(
                                color: Color(0xFF262626),
                                child: Icon(Icons.image_outlined),
                              ),
                            if (item.type == AssetType.video)
                              Positioned(
                                right: 6,
                                bottom: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    _formatClock(item.duration),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            if (tooLong)
                              const ColoredBox(
                                color: Color(0xB3000000),
                                child: Center(
                                  child: Text(
                                    'Max 1 min',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
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
    bool seen(List<Map<String, dynamic>> rows) => rows.every(
      (story) => _viewedStoryIds.contains((story['id'] ?? '').toString()),
    );
    // Unseen stories first, already-viewed (grey ring) ones move to the end,
    // exactly like Instagram. Order inside each group is kept stable.
    final otherIds = grouped.keys.toList()
      ..sort((a, b) {
        final sa = _viewedStoriesLoaded && seen(grouped[a]!) ? 1 : 0;
        final sb = _viewedStoriesLoaded && seen(grouped[b]!) ? 1 : 0;
        return sa.compareTo(sb);
      });

    return Container(
      height: 108,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: igBorder, width: 0.5)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
    final allViewed =
        stories.isNotEmpty &&
        stories.every(
          (story) => _viewedStoryIds.contains((story['id'] ?? '').toString()),
        );
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
              pageBuilder: (_, animation, _) => StoryViewer(
                stories: stories,
                initialProfile: profile,
                onStoryViewed: (storyId) {
                  if (mounted) _markStoryViewed(storyId);
                },
              ),
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
                // Ring: pink/orange gradient while there is something new,
                // flat grey once every story of this person has been seen.
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient:
                        stories.isNotEmpty && !allViewed && _viewedStoriesLoaded
                        ? igStoryGradient
                        : null,
                    border: stories.isEmpty
                        ? null
                        : (allViewed && _viewedStoriesLoaded)
                        ? Border.all(color: igSeenRing, width: 1.5)
                        : null,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: igBlack,
                    ),
                    child: CircleAvatar(
                      radius: 28,
                      backgroundColor: igElevated,
                      backgroundImage: _isImageSource(avatar)
                          ? _twiceAvatarProvider(avatar)
                          : null,
                      child: _isImageSource(avatar)
                          ? null
                          : const Icon(
                              Icons.person_rounded,
                              color: muted,
                              size: 30,
                            ),
                    ),
                  ),
                ),
                if (own)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: violet,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: openCreator,
                        child: Container(
                          width: 25,
                          height: 25,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: igBlack, width: 2),
                          ),
                          child: const Icon(
                            Icons.add_rounded,
                            size: 17,
                            color: Colors.white,
                          ),
                        ),
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
    required this.onStoryViewed,
  });

  final List<Map<String, dynamic>> stories;
  final Map<String, dynamic> initialProfile;
  final ValueChanged<String> onStoryViewed;

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer>
    with TickerProviderStateMixin {
  static const int _maxVideoSeconds = 60;

  late final AnimationController _progress;
  late final AnimationController _burst;
  final TextEditingController _reply = TextEditingController();
  final FocusNode _replyFocus = FocusNode();
  VideoPlayerController? _video;
  int _index = 0;
  bool _paused = false;
  bool _videoReady = false;
  bool _holdForInput = false;
  bool _sheetOpen = false;
  bool _sending = false;
  bool _liked = false;
  int _viewerCount = 0;
  final Set<String> _recorded = {};

  Map<String, dynamic> get _story => widget.stories[_index];
  String get _storyId => (_story['id'] ?? '').toString();
  String get _url => (_story['resolved_url'] ?? '').toString();
  bool get _isVideo => _story['media_type'] == 'video';
  String get _ownerId => (_story['user_id'] ?? '').toString();
  bool get _isOwner =>
      _ownerId.isNotEmpty &&
      _ownerId == (Supabase.instance.client.auth.currentUser?.id ?? '');

  @override
  void initState() {
    super.initState();
    _progress =
        AnimationController(vsync: this, duration: const Duration(seconds: 5))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && mounted && !_isVideo) {
              _next(completed: true);
            }
          });
    _burst = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _replyFocus.addListener(() {
      _holdForInput = _replyFocus.hasFocus;
      if (_holdForInput) {
        _pause();
      } else if (!_sheetOpen) {
        _resume();
      }
    });
    _loadCurrent();
  }

  // A story counts as seen the moment it is shown (not only when it plays to
  // the end), so the pink ring turns grey as soon as you open it. Deferred to
  // after the frame because the story strip calls setState in response.
  void _markSeen() {
    final id = _storyId;
    if (id.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onStoryViewed(id);
    });
  }

  Future<void> _loadStoryMeta() async {
    final id = _storyId;
    if (id.isEmpty) return;
    final repo = SocialRepository.instance;
    if (_isOwner) {
      try {
        final count = await repo.storyViewCount(id);
        if (mounted && id == _storyId) setState(() => _viewerCount = count);
      } catch (_) {}
    } else {
      if (_recorded.add(id)) unawaited(repo.recordStoryView(id));
      try {
        final liked = await repo.myStoryLike(id);
        if (mounted && id == _storyId) setState(() => _liked = liked);
      } catch (_) {}
    }
  }

  Future<void> _loadCurrent() async {
    _progress.stop();
    _progress.value = 0;
    final previous = _video;
    _video = null;
    _videoReady = false;
    _liked = false;
    _viewerCount = 0;
    if (previous != null) {
      previous.removeListener(_onVideoTick);
      await previous.pause();
      await previous.dispose();
    }
    if (!mounted) return;
    unawaited(_loadStoryMeta());
    _markSeen();

    if (_url.isEmpty) {
      _progress.duration = const Duration(seconds: 5);
      if (!_paused) _progress.forward();
      setState(() {});
      return;
    }

    if (_isVideo) {
      final controller = _url.startsWith('file://')
          ? VideoPlayerController.file(File.fromUri(Uri.parse(_url)))
          : VideoPlayerController.networkUrl(Uri.parse(_url));
      _video = controller;
      try {
        await controller.initialize();
        if (!mounted || _video != controller) return;
        _videoReady = true;
        controller.addListener(_onVideoTick);
        if (!_paused) await controller.play();
      } catch (_) {
        _videoReady = false;
      }
    }
    if (!mounted) return;
    if (!_isVideo || !_videoReady) {
      _progress.duration = const Duration(seconds: 5);
      if (!_paused) _progress.forward();
    }
    setState(() {});
  }

  // The top bar for a video follows the real playback position, so its length
  // matches the length of the story (like Facebook), capped at 60 seconds.
  void _onVideoTick() {
    final controller = _video;
    if (controller == null || !controller.value.isInitialized) return;
    final total = controller.value.duration;
    if (total <= Duration.zero) return;
    final cap = Duration(seconds: _maxVideoSeconds);
    final limit = total > cap ? cap : total;
    final position = controller.value.position;
    _progress.value = (position.inMilliseconds / limit.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    if (position >= limit && mounted) _next(completed: true);
  }

  Future<void> _openOwnerProfile() async {
    if (_ownerId.isEmpty) return;
    await _pause();
    if (!mounted) return;
    await _openUserProfile(
      context,
      userId: _ownerId,
      profile: Map<String, dynamic>.from(
        _story['profiles'] as Map? ?? widget.initialProfile,
      ),
    );
    if (mounted && !_holdForInput && !_sheetOpen) _resume();
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
    if (_videoReady) {
      await _video?.play();
    } else {
      _progress.forward();
    }
    if (mounted) setState(() {});
  }

  void _next({bool completed = false}) {
    if (completed) {
      final id = _storyId;
      if (id.isNotEmpty) widget.onStoryViewed(id);
    }
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
        _progress.forward(from: 0);
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

  Future<void> _toggleLike() async {
    final id = _storyId;
    if (id.isEmpty || _isOwner) return;
    final next = !_liked;
    setState(() => _liked = next);
    if (next) _burst.forward(from: 0);
    try {
      await SocialRepository.instance.setStoryLike(id, next);
    } catch (e) {
      if (!mounted) return;
      setState(() => _liked = !next);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not update like: $e')));
    }
  }

  Future<void> _sendReply() async {
    final text = _reply.text.trim();
    if (text.isEmpty || _sending || _ownerId.isEmpty) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SocialRepository.instance.replyToStory(_ownerId, text);
      if (!mounted) return;
      _reply.clear();
      _replyFocus.unfocus();
      messenger.showSnackBar(const SnackBar(content: Text('Reply sent')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not send: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openViewers() async {
    final id = _storyId;
    if (id.isEmpty) return;
    _sheetOpen = true;
    await _pause();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: igSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _StoryViewersSheet(storyId: id),
    );
    _sheetOpen = false;
    if (!mounted) return;
    unawaited(_loadStoryMeta());
    if (!_holdForInput) _resume();
  }

  @override
  void dispose() {
    _progress.dispose();
    _burst.dispose();
    _reply.dispose();
    _replyFocus.dispose();
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    super.dispose();
  }

  Widget _bottomBar(BuildContext context) {
    if (_isOwner) {
      return Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: _openViewers,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.remove_red_eye_outlined,
                  color: Colors.white,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Text(
                  _viewerCount == 1 ? '1 viewer' : '$_viewerCount viewers',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final hasText = _reply.text.trim().isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _reply,
            focusNode: _replyFocus,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.send,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _sendReply(),
            style: const TextStyle(color: Colors.white),
            cursorColor: Colors.white,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Reply…',
              hintStyle: const TextStyle(color: Colors.white70),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 12,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
                borderSide: const BorderSide(color: Colors.white54),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
                borderSide: const BorderSide(color: Colors.white),
              ),
              suffixIcon: hasText
                  ? (_sending
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                          )
                        : IconButton(
                            onPressed: _sendReply,
                            icon: const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                            ),
                          ))
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 10),
        _StoryHeartButton(liked: _liked, onTap: _toggleLike),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = Map<String, dynamic>.from(
      _story['profiles'] as Map? ?? widget.initialProfile,
    );
    final avatar = (user['avatar_url'] ?? '').toString();
    final url = _url;
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPressStart: (_) => _pause(),
              onLongPressEnd: (_) {
                if (!_holdForInput && !_sheetOpen) _resume();
              },
              onTapUp: (details) {
                if (_holdForInput) {
                  _replyFocus.unfocus();
                  return;
                }
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
                        : (_isImageSource(url)
                              ? Image(
                                  image: _twiceImageProvider(url),
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
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
                    child: AnimatedBuilder(
                      animation: _progress,
                      builder: (context, _) => Row(
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
                                      ? _progress.value.clamp(0.0, 1.0)
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
                  ),
                  Positioned(
                    top: 22,
                    left: 12,
                    right: 8,
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: _openOwnerProfile,
                          child: CircleAvatar(
                            radius: 17,
                            backgroundImage: _isImageSource(avatar)
                                ? _twiceAvatarProvider(avatar)
                                : null,
                            child: _isImageSource(avatar)
                                ? null
                                : const Icon(Icons.person, size: 18),
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _openOwnerProfile,
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text:
                                        (user['username'] ??
                                                user['display_name'] ??
                                                'twice_user')
                                            .toString()
                                            .replaceFirst(RegExp(r'^@'), ''),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                    ),
                                  ),
                                  // Timestamp of this story, e.g. "3h".
                                  TextSpan(
                                    text:
                                        '   ${_storyAge(_story['created_at'])}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w400,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                      bottom: 96 + keyboard,
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
                  if (_paused && !_holdForInput && !_sheetOpen)
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
            // Floating hearts when you like a story.
            Positioned(
              right: 12,
              bottom: 70 + keyboard,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _burst,
                  builder: (context, _) {
                    if (!_burst.isAnimating && _burst.value == 0) {
                      return const SizedBox.shrink();
                    }
                    final t = _burst.value;
                    const dx = [-14.0, 10.0, -30.0, 24.0, -2.0];
                    const delay = [0.0, 0.08, 0.16, 0.05, 0.22];
                    return SizedBox(
                      width: 70,
                      height: 260,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (var i = 0; i < dx.length; i++)
                            Builder(
                              builder: (context) {
                                final p = ((t - delay[i]) / (1 - delay[i]))
                                    .clamp(0.0, 1.0);
                                return Positioned(
                                  right: 18 - dx[i] * p,
                                  bottom: 220 * Curves.easeOut.transform(p),
                                  child: Opacity(
                                    opacity: (1 - p).clamp(0.0, 1.0),
                                    child: Transform.scale(
                                      scale: 0.7 + 0.7 * (1 - p),
                                      child: const Icon(
                                        Icons.favorite_rounded,
                                        color: Color(0xFFFF3040),
                                        size: 28,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 12 + keyboard,
              child: _bottomBar(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryHeartButton extends StatefulWidget {
  const _StoryHeartButton({required this.liked, required this.onTap});

  final bool liked;
  final VoidCallback onTap;

  @override
  State<_StoryHeartButton> createState() => _StoryHeartButtonState();
}

class _StoryHeartButtonState extends State<_StoryHeartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void didUpdateWidget(covariant _StoryHeartButton old) {
    super.didUpdateWidget(old);
    if (widget.liked && !old.liked) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: AnimatedBuilder(
            animation: _pop,
            builder: (context, _) {
              final t = _pop.value;
              final scale = widget.liked && _pop.isAnimating
                  ? 1 + 0.45 * sin(t * pi)
                  : 1.0;
              return Transform.scale(
                scale: scale,
                child: Icon(
                  widget.liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: widget.liked ? const Color(0xFFFF3040) : Colors.white,
                  size: 32,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _StoryViewersSheet extends StatefulWidget {
  const _StoryViewersSheet({required this.storyId});

  final String storyId;

  @override
  State<_StoryViewersSheet> createState() => _StoryViewersSheetState();
}

class _StoryViewersSheetState extends State<_StoryViewersSheet> {
  List<Map<String, dynamic>>? rows;
  String? loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await SocialRepository.instance.storyViewers(widget.storyId);
      if (mounted) setState(() => rows = data);
    } catch (e) {
      if (mounted) setState(() => loadError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = rows;
    return SizedBox(
      height: MediaQuery.of(context).size.height * .6,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.remove_red_eye_outlined, color: ink),
                const SizedBox(width: 8),
                Text(
                  list == null ? 'Viewers' : 'Viewers · ${list.length}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: loadError != null
                ? Center(child: Text('Could not load viewers\n$loadError'))
                : list == null
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                ? const Center(
                    child: Text(
                      'No one has viewed this story yet.',
                      style: TextStyle(color: muted),
                    ),
                  )
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final row = list[i];
                      final profile = Map<String, dynamic>.from(
                        row['profile'] as Map? ?? const {},
                      );
                      final avatar = (profile['avatar_url'] ?? '').toString();
                      final name =
                          (profile['display_name'] ??
                                  profile['username'] ??
                                  'Twice user')
                              .toString();
                      return ListTile(
                        onTap: () => _openUserProfile(
                          context,
                          userId: (profile['id'] ?? '').toString(),
                          profile: profile,
                        ),
                        leading: CircleAvatar(
                          backgroundImage: _isImageSource(avatar)
                              ? _twiceAvatarProvider(avatar)
                              : null,
                          child: _isImageSource(avatar)
                              ? null
                              : const Icon(Icons.person),
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(_timeAgo(row['viewed_at'])),
                        trailing: row['liked'] == true
                            ? const Icon(
                                Icons.favorite_rounded,
                                color: Color(0xFFFF3040),
                              )
                            : null,
                      );
                    },
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
    color: Colors.white,
    backgroundColor: igElevated,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      scrollCacheExtent: ScrollCacheExtent.pixels(2500),
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
      children: [
        StoryStrip(
          key: storyStripKey,
          onCreateStory: onCreateStory,
          profile: profile,
          stories: stories,
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
          // Organic posts + a native video ad after every N posts, all in the
          // same list so ads scroll inline like any other post.
          ...interleaveAds<SocialPost>(posts).map(
            (entry) => entry.isAd
                ? FeedNativeAdCard(
                    key: ValueKey('ad-slot-${entry.adSlot}'),
                    slot: entry.adSlot!,
                  )
                : PostCard(
                    key: ValueKey('post-${entry.item!.id}'),
                    post: entry.item!,
                    onLike: onLike,
                    onCommentChanged: onCommentChanged,
                  ),
          ),
      ],
    ),
  );
}

/// Instagram-style comment bubble (round bubble with a tail at bottom-left).
class _InstagramCommentIcon extends StatelessWidget {
  const _InstagramCommentIcon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _InstagramCommentPainter(color),
  );
}

class _InstagramCommentPainter extends CustomPainter {
  const _InstagramCommentPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final path = Path()
      ..moveTo(20.656, 17.008)
      ..arcToPoint(
        const Offset(17.066, 20.623),
        radius: const Radius.circular(9.993),
        largeArc: true,
        clockwise: false,
      )
      ..lineTo(22, 22)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _InstagramCommentPainter old) =>
      old.color != color;
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
        color: widget.liked ? igRed : ink,
      ),
    ),
  );
}

class _PostMediaItem extends StatefulWidget {
  const _PostMediaItem({super.key, required this.media});

  final Map<String, dynamic> media;

  @override
  State<_PostMediaItem> createState() => _PostMediaItemState();
}

class _PostMediaItemState extends State<_PostMediaItem> {
  VideoPlayerController? _controller;
  String _sourceInUse = '';
  bool _failed = false;
  bool _userPaused = false;
  bool _showVideoControls = true;
  bool _hasVideoFrame = false;
  bool _initializing = false;
  double _visibleFraction = 0;
  Timer? _controlsTimer;
  Timer? _releaseTimer;

  bool get _isVideo =>
      (widget.media['media_type'] ?? '').toString().toLowerCase() == 'video';

  String get _url => (widget.media['resolved_url'] ?? '').toString().trim();

  String get _thumbnailUrl =>
      (widget.media['resolved_thumbnail_url'] ?? '').toString().trim();

  // Facebook-style: the poster is always drawn; the video decoder only exists
  // while the post is on (or next to) the screen, so scrolling stays smooth.
  Future<void> _ensureController() async {
    if (!_isVideo || _controller != null || _initializing || _failed) return;
    _initializing = true;
    if (mounted) setState(() {});
    try {
      await _initializeVideo();
    } finally {
      _initializing = false;
      if (mounted) setState(() {});
    }
    if (mounted && _visibleFraction <= 0.05) _scheduleRelease();
  }

  Future<void> _initializeVideo({bool allowUrlRefresh = true}) async {
    if (!_isVideo) return;

    if (_url.isEmpty) {
      if (allowUrlRefresh && await _refreshAndRetryVideo()) return;
      if (mounted) setState(() => _failed = true);
      return;
    }

    var source = _url;
    if (source.startsWith('http')) {
      final local = await TwiceMedia.cachedFileUri(source);
      if (local != null) source = local;
    }
    if (!mounted) return;

    final controller = source.startsWith('file://')
        ? VideoPlayerController.file(File.fromUri(Uri.parse(source)))
        : VideoPlayerController.networkUrl(Uri.parse(source));
    _controller = controller;
    _sourceInUse = source;
    controller.addListener(_onVideoValueChanged);

    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(1);
      if (!mounted || !identical(_controller, controller)) {
        controller.removeListener(_onVideoValueChanged);
        await controller.dispose();
        return;
      }
      setState(() {});
      _syncPlayback(controller);
    } catch (_) {
      controller.removeListener(_onVideoValueChanged);
      await controller.dispose();
      if (identical(_controller, controller)) _controller = null;

      // Retry once with a fresh signed URL or an available offline copy.
      if (allowUrlRefresh && await _refreshAndRetryVideo()) return;
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<bool> _refreshAndRetryVideo() async {
    final objectPath = (widget.media['media_url'] ?? '').toString().trim();
    if (objectPath.isEmpty ||
        objectPath.startsWith('http://') ||
        objectPath.startsWith('https://')) {
      return false;
    }

    try {
      final refreshed = await SocialRepository.instance.refreshMediaUrl(
        objectPath,
        bucket: 'post-media',
      );
      if (refreshed == null || refreshed.isEmpty || !mounted) return false;

      widget.media['resolved_url'] = refreshed;
      setState(() => _failed = false);
      await _initializeVideo(allowUrlRefresh: false);

      final active = _controller;
      final succeeded =
          mounted &&
          active != null &&
          active.value.isInitialized &&
          !active.value.hasError;

      if (!succeeded && mounted) {
        setState(() => _failed = true);
      }
      return succeeded;
    } catch (_) {
      return false;
    }
  }

  void _onVideoValueChanged() {
    final controller = _controller;
    if (!mounted || controller == null || _hasVideoFrame) return;
    if (controller.value.isInitialized &&
        controller.value.position > Duration.zero) {
      setState(() => _hasVideoFrame = true);
    }
  }

  void _scheduleRelease() {
    _releaseTimer?.cancel();
    _releaseTimer = Timer(const Duration(seconds: 4), _releaseController);
  }

  void _releaseController() {
    if (!mounted || _visibleFraction > 0.05) return;
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    _hasVideoFrame = false;
    controller.removeListener(_onVideoValueChanged);
    controller.pause();
    controller.dispose();
    setState(() {});
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
        // Save the video to disk while watching: replays are instant/offline.
        if (_sourceInUse.startsWith('http')) {
          unawaited(TwiceMedia.cacheVideo(_sourceInUse));
        }
      }
    } else if (controller.value.isPlaying) {
      controller.pause();
    }
  }

  void _onVideoTap() {
    if (_failed) {
      setState(() => _failed = false);
      _ensureController();
      return;
    }
    _showControlsTemporarily();
  }

  @override
  void didUpdateWidget(covariant _PostMediaItem oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Signed URLs may refresh while the underlying media object stays the same.
    // Keep the existing player in that case to avoid feed-scroll flicker.
    final oldPath = oldWidget.media['media_url'];
    final newPath = widget.media['media_url'];
    if (oldPath != newPath ||
        oldWidget.media['media_type'] != widget.media['media_type']) {
      final old = _controller;
      _controller = null;
      old?.removeListener(_onVideoValueChanged);
      old?.pause();
      old?.dispose();
      _failed = false;
      _userPaused = false;
      _hasVideoFrame = false;
      if (_visibleFraction >= 0.25) _ensureController();
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _releaseTimer?.cancel();
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onVideoValueChanged);
      controller.pause();
      controller.dispose();
    }
    super.dispose();
  }

  Widget _brokenImage() => const Center(
    child: Icon(Icons.broken_image_outlined, size: 42, color: muted),
  );

  @override
  Widget build(BuildContext context) {
    final url = _url;

    if (!_isVideo) {
      return ColoredBox(
        color: const Color(0xFF262626),
        child: url.isEmpty
            ? _brokenImage()
            : Image(
                image: _twiceImageProvider(url),
                fit: BoxFit.cover,
                width: double.infinity,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, sync) => sync
                    ? child
                    : AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 180),
                        child: child,
                      ),
                errorBuilder: (_, _, _) => _brokenImage(),
              ),
      );
    }

    final controller = _controller;
    final showingVideo =
        !_failed &&
        controller != null &&
        controller.value.isInitialized &&
        _hasVideoFrame;

    final active = showingVideo ? controller : null;

    return VisibilityDetector(
      key: ValueKey('twice-video-${widget.media['media_url'] ?? url}'),
      onVisibilityChanged: (info) {
        if (!mounted) return;
        _visibleFraction = info.visibleFraction;
        if (_visibleFraction > 0.05) {
          _releaseTimer?.cancel();
          if (_controller == null && _visibleFraction >= 0.25) {
            _ensureController();
          }
        } else {
          _scheduleRelease();
        }
        final current = _controller;
        if (current != null) _syncPlayback(current);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onVideoTap,
        child: Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            // The thumbnail is ALWAYS underneath: never a blank/grey box.
            TwiceVideoPoster(
              videoUrl: url,
              thumbnailUrl: _thumbnailUrl,
              imageProviderFor: _twiceImageProvider,
              showPlayIcon: !showingVideo && !_initializing && !_failed,
            ),
            if (active != null)
              FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: active.value.size.width,
                  height: active.value.size.height,
                  child: VideoPlayer(active),
                ),
              ),
            if (_initializing && !showingVideo && !_failed)
              const Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Colors.white,
                  ),
                ),
              ),
            if (_failed)
              const Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0x99000000),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(
                      Icons.refresh_rounded,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                ),
              ),
            if (active != null && _showVideoControls)
              Center(
                child: Material(
                  color: const Color(0x99000000),
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: active.value.isPlaying
                        ? 'Pause video'
                        : 'Play video',
                    onPressed: () {
                      if (active.value.isPlaying) {
                        _userPaused = true;
                        active.pause();
                      } else {
                        _userPaused = false;
                        _syncPlayback(active);
                      }
                      _showControlsTemporarily();
                    },
                    icon: Icon(
                      active.value.isPlaying
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
    );
  }
}

class _PostFollowButton extends StatefulWidget {
  const _PostFollowButton({required this.profileId, required this.onChanged});

  final String profileId;
  final VoidCallback onChanged;

  @override
  State<_PostFollowButton> createState() => _PostFollowButtonState();
}

class _PostFollowButtonState extends State<_PostFollowButton> {
  String _label = '';
  bool _loading = true;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PostFollowButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profileId != widget.profileId) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (widget.profileId.isEmpty) {
      if (mounted) {
        setState(() {
          _label = '';
          _loading = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _loading = true);
    try {
      final label = await SocialRepository.instance.getFollowLabel(
        widget.profileId,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _label = label;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _label = '';
          _loading = false;
        });
        debugPrint('Follow state load failed: $e');
      }
    }
  }

  Future<void> _tap() async {
    if (_busy || widget.profileId.isEmpty || _label.isEmpty) return;
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
        final privateAccount = await repo.isPrivateAccount(widget.profileId);
        setState(() {
          _label = privateAccount ? 'Requested' : 'Following';
        });
        await repo.follow(widget.profileId, privateAccount: privateAccount);
      }
      await _load();
      widget.onChanged();
    } catch (e) {
      if (mounted) {
        setState(() => _label = previous);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not update follow: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.profileId.isEmpty || _label.isEmpty) {
      return const SizedBox.shrink();
    }
    final active = _label == 'Following' || _label == 'Connected';
    return TextButton(
      onPressed: _loading || _busy ? null : _tap,
      style: TextButton.styleFrom(
        foregroundColor: active ? muted : igBlue,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      child: _loading || _busy
          ? const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          : Text(
              _label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
    );
  }
}

class PostCard extends StatefulWidget {
  const PostCard({
    super.key,
    required this.post,
    required this.onLike,
    required this.onCommentChanged,
    this.authorTappable = true,
  });

  final bool authorTappable;
  final SocialPost post;
  final ValueChanged<SocialPost> onLike;
  final VoidCallback onCommentChanged;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard>
    with SingleTickerProviderStateMixin {
  // Double-tap heart: pop in 150 ms (scale 50% -> 110%, opacity 0 -> 100%),
  // hold 100 ms, then fade out over 150 ms. 400 ms in total.
  late final AnimationController _heart = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final Animation<double> _heartScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 0.5,
        end: 1.1,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 150,
    ),
    TweenSequenceItem(tween: ConstantTween<double>(1.1), weight: 250),
  ]).animate(_heart);
  late final Animation<double> _heartOpacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 150),
    TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 100),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 0.0,
      ).chain(CurveTween(curve: Curves.linear)),
      weight: 150,
    ),
  ]).animate(_heart);

  int _page = 0;
  int _lastDownMs = -10000;
  Offset _lastDownPos = Offset.zero;

  @override
  void dispose() {
    _heart.dispose();
    super.dispose();
  }

  // A Listener never joins the gesture arena, so a double tap is detected on
  // photos AND videos without breaking swiping or the video's own tap.
  void _onPointerDown(PointerDownEvent event) {
    final now = event.timeStamp.inMilliseconds;
    if (now - _lastDownMs < 300 &&
        (event.position - _lastDownPos).distance < 80) {
      _lastDownMs = -10000;
      _doubleTapLike();
    } else {
      _lastDownMs = now;
      _lastDownPos = event.position;
    }
  }

  void _doubleTapLike() {
    _heart.forward(from: 0);
    HapticFeedback.lightImpact();
    // Instagram: double tap only ever likes, it never un-likes.
    if (!widget.post.liked) widget.onLike(widget.post);
  }

  Future<void> _openComments() async {
    final post = widget.post;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      enableDrag: true,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (_) => CommentsSheet(post: post),
    );
    try {
      final n = await SocialRepository.instance.commentCount(post.id);
      post.data['comments'] = [
        {'count': n},
      ];
    } catch (_) {}
    widget.onCommentChanged();
  }

  Future<void> _share() async {
    final post = widget.post;
    try {
      await SharePlus.instance.share(
        ShareParams(text: '${post.username} on Twice: ${post.caption}'.trim()),
      );
    } catch (e) {
      debugPrint('Share failed: $e');
    }
  }

  void _toggleSave() {
    final post = widget.post;
    final wasSaved = post.saved;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;

    final rows = List<Map<String, dynamic>>.from(
      (post.data['saved_posts'] as List? ?? const []).whereType<Map>().map(
        (row) => Map<String, dynamic>.from(row),
      ),
    );

    // Update the bookmark immediately.
    if (wasSaved) {
      rows.removeWhere((row) => row['user_id'] == uid);
    } else {
      rows.add({'user_id': uid});
    }
    post.data['saved_posts'] = rows;
    widget.onCommentChanged();

    // Persist asynchronously; do not reload the feed.
    SocialRepository.instance.toggleSaved(post.id, wasSaved).catchError((
      Object e,
    ) {
      if (!mounted) return;
      // Roll back only this bookmark state.
      final current = List<Map<String, dynamic>>.from(
        (post.data['saved_posts'] as List? ?? const []).whereType<Map>().map(
          (row) => Map<String, dynamic>.from(row),
        ),
      );
      current.removeWhere((row) => row['user_id'] == uid);
      if (wasSaved) current.add({'user_id': uid});
      post.data['saved_posts'] = current;
      widget.onCommentChanged();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    });
  }

  Widget _avatar(String? url) {
    const placeholder = ColoredBox(
      color: igElevated,
      child: Icon(Icons.person_outline_rounded, color: muted, size: 20),
    );
    return SizedBox(
      width: 32,
      height: 32,
      child: ClipOval(
        child: (url ?? '').trim().isEmpty
            ? placeholder
            : Image(
                image: _twiceAvatarProvider(url!),
                gaplessPlayback: true,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final media = post.media;
    final username = post.username.replaceFirst(RegExp(r'^@'), '');
    final comments = post.commentCount;
    final createdAt = post.data['created_at'];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- Header: avatar, bold username, follow, 3-dot menu ----
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.authorTappable
                        ? () => _openUserProfile(
                            context,
                            userId: (post.author['id'] ?? '').toString(),
                            profile: post.author,
                          )
                        : null,
                    child: Row(
                      children: [
                        _avatar(post.avatarUrl),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (post.author['id'] != null &&
                    post.author['id'].toString().isNotEmpty)
                  _PostFollowButton(
                    profileId: post.author['id'].toString(),
                    onChanged: widget.onCommentChanged,
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Post options',
                  icon: const Icon(Icons.more_horiz_rounded, color: ink),
                  onSelected: (value) {
                    if (value == 'share') _share();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'share',
                      child: Row(
                        children: [
                          Icon(Icons.ios_share_rounded, size: 19),
                          SizedBox(width: 10),
                          Text('Share'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ---- Media: 1:1 (single) or 4:5 (carousel), double-tap to like ----
          if (media.isNotEmpty)
            AspectRatio(
              aspectRatio: media.length == 1 ? 1 : 0.8,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _onPointerDown,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PageView.builder(
                      itemCount: media.length,
                      onPageChanged: (i) => setState(() => _page = i),
                      itemBuilder: (context, index) {
                        final item = media[index];
                        return _PostMediaItem(
                          key: ValueKey(
                            'media-${item['id'] ?? item['media_url']}',
                          ),
                          media: item,
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
                              vertical: 4,
                            ),
                            child: Text(
                              '${_page + 1}/${media.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    // Big white heart that pops out of the centre on double tap.
                    IgnorePointer(
                      child: Center(
                        child: AnimatedBuilder(
                          animation: _heart,
                          builder: (context, _) {
                            if (_heart.isDismissed) {
                              return const SizedBox.shrink();
                            }
                            return Opacity(
                              opacity: _heartOpacity.value.clamp(0.0, 1.0),
                              child: Transform.scale(
                                scale: _heartScale.value,
                                child: const Icon(
                                  Icons.favorite_rounded,
                                  color: Colors.white,
                                  size: 96,
                                  shadows: [
                                    Shadow(
                                      blurRadius: 24,
                                      color: Color(0x66000000),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ---- Action row: like / comment / share ... bookmark ----
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SizedBox(
              height: 46,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Row(
                    children: [
                      _AnimatedLikeButton(
                        liked: post.liked,
                        onPressed: () => widget.onLike(post),
                      ),
                      IconButton(
                        tooltip: 'Comment',
                        onPressed: _openComments,
                        icon: const _InstagramCommentIcon(size: 25, color: ink),
                      ),
                      IconButton(
                        tooltip: 'Share',
                        onPressed: _share,
                        icon: const Icon(Icons.send_outlined, size: 25),
                      ),
                      const Spacer(),
                      _BookmarkButton(
                        saved: post.saved,
                        onPressed: _toggleSave,
                      ),
                    ],
                  ),
                  if (media.length > 1)
                    IgnorePointer(
                      child: _PageDots(count: media.length, index: _page),
                    ),
                ],
              ),
            ),
          ),

          // ---- Likes, caption, comments link, time ----
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  post.likes == 0
                      ? 'Be the first to like this'
                      : '${_withCommas(post.likes)} ${post.likes == 1 ? 'like' : 'likes'}',
                  style: TextStyle(
                    fontWeight: post.likes == 0
                        ? FontWeight.w400
                        : FontWeight.w700,
                    fontSize: 14,
                    color: ink,
                  ),
                ),
                if (post.caption.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      style: const TextStyle(
                        color: ink,
                        fontSize: 14,
                        height: 1.3,
                      ),
                      children: [
                        TextSpan(
                          text: '$username ',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        ..._captionSpans(post.caption),
                      ],
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openComments,
                  child: Text(
                    comments > 0
                        ? (comments == 1
                              ? 'View 1 comment'
                              : 'View all $comments comments')
                        : 'Add a comment…',
                    style: const TextStyle(color: muted, fontSize: 14),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _timeAgo(createdAt).toUpperCase(),
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _withCommas(int value) => value.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (match) => ',',
);

/// Caption text with #hashtags and @mentions highlighted in Instagram blue.
List<InlineSpan> _captionSpans(String text) {
  final spans = <InlineSpan>[];
  var last = 0;
  final pattern = RegExp(r'(#[\p{L}\p{N}_]+|@[\w.]+)', unicode: true);
  for (final match in pattern.allMatches(text)) {
    if (match.start > last) {
      spans.add(TextSpan(text: text.substring(last, match.start)));
    }
    spans.add(
      TextSpan(
        text: match.group(0),
        style: const TextStyle(color: igHashtagBlue),
      ),
    );
    last = match.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

/// Carousel position dots (active = blue, others grey).
class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < count; i++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.symmetric(horizontal: 2.5),
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i == index ? igBlue : const Color(0xFF5A5A5A),
          ),
        ),
    ],
  );
}

/// Bookmark: outline -> solid white, with a quick vertical bounce.
class _BookmarkButton extends StatefulWidget {
  const _BookmarkButton({required this.saved, required this.onPressed});

  final bool saved;
  final VoidCallback onPressed;

  @override
  State<_BookmarkButton> createState() => _BookmarkButtonState();
}

class _BookmarkButtonState extends State<_BookmarkButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );
  late final Animation<double> _dy = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 0.0,
        end: -7.0,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: -7.0,
        end: 0.0,
      ).chain(CurveTween(curve: Curves.bounceOut)),
      weight: 70,
    ),
  ]).animate(_bounce);

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.saved ? 'Remove saved post' : 'Save post',
    onPressed: () {
      _bounce.forward(from: 0);
      widget.onPressed();
    },
    icon: AnimatedBuilder(
      animation: _dy,
      builder: (context, child) =>
          Transform.translate(offset: Offset(0, _dy.value), child: child),
      child: Icon(
        widget.saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
        size: 27,
        color: Colors.white,
      ),
    ),
  );
}

/// Short Instagram-style age for stories: "now", "5m", "3h", "1d".
String _storyAge(dynamic value) {
  final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (date == null) return '';
  final diff = DateTime.now().difference(date);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  return '${diff.inDays}d';
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

Future<List<AssetEntity>> _loadSelectableMedia({int size = 200}) async {
  // Query images and videos independently: some Android gallery providers
  // omit video rows from RequestType.common when access is partially granted.
  final permission = await PhotoManager.requestPermissionExtend();
  if (!permission.isAuth && !permission.hasAccess) return <AssetEntity>[];

  final results = <String, AssetEntity>{};
  for (final type in <RequestType>[RequestType.image, RequestType.video]) {
    final paths = await PhotoManager.getAssetPathList(
      type: type,
      onlyAll: true,
    );
    if (paths.isEmpty) continue;
    final assets = await paths.first.getAssetListPaged(page: 0, size: size);
    for (final asset in assets) {
      if (asset.type == AssetType.image || asset.type == AssetType.video) {
        results[asset.id] = asset;
      }
    }
  }
  final assets = results.values.toList()
    ..sort(
      (a, b) => (b.createDateSecond ?? 0).compareTo(a.createDateSecond ?? 0),
    );
  return assets;
}

class CreatePage extends StatefulWidget {
  const CreatePage({super.key, required this.onPost, required this.profile});
  final Map<String, dynamic> profile;
  final Future<void> Function(
    String caption,
    List<AssetEntity> media,
    String visibility,
  )
  onPost;
  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage> {
  final controller = TextEditingController();
  final selectedMedia = <AssetEntity>[];
  String visibility = 'public';
  bool publishing = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    List<AssetEntity> assets;
    try {
      assets = await _loadSelectableMedia(size: 300);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open media library: $error')),
        );
      }
      return;
    }
    if (!mounted) return;
    if (assets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No accessible photos or videos. Check media permissions.',
          ),
        ),
      );
      return;
    }

    final picked = await showModalBottomSheet<List<AssetEntity>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _MediaPicker(assets: assets),
    );

    if (picked != null && mounted) {
      final videos = picked
          .where((asset) => asset.type == AssetType.video)
          .take(1)
          .toList();
      final photos = picked
          .where((asset) => asset.type == AssetType.image)
          .take(10)
          .toList();
      final validMedia = videos.isNotEmpty ? videos : photos;

      setState(() {
        selectedMedia
          ..clear()
          ..addAll(validMedia);
      });
    }
  }

  Future<void> _publish() async {
    if (publishing) return;
    setState(() => publishing = true);
    try {
      await widget.onPost(controller.text, selectedMedia, visibility);
      controller.clear();
      setState(() => selectedMedia.clear());
    } catch (_) {
    } finally {
      if (mounted) setState(() => publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: igBlack,
    appBar: AppBar(
      backgroundColor: igBlack,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        tooltip: 'Close',
        onPressed: () => Navigator.of(context).maybePop(),
        icon: const Icon(Icons.close, color: Colors.white, size: 28),
      ),
      title: const Text(
        'Create post',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Center(
            child: FilledButton(
              onPressed: publishing ? null : _publish,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF0095F6),
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
                Builder(
                  builder: (context) {
                    final avatar = (widget.profile['avatar_url'] ?? '')
                        .toString()
                        .trim();
                    final displayName = (widget.profile['display_name'] ?? '')
                        .toString()
                        .trim();
                    final username = (widget.profile['username'] ?? '')
                        .toString()
                        .trim();
                    final name = displayName.isNotEmpty
                        ? displayName
                        : (username.isNotEmpty ? username : 'Twice user');

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 25,
                          backgroundColor: const Color(0xFF262626),
                          backgroundImage: _isImageSource(avatar)
                              ? _twiceAvatarProvider(avatar)
                              : null,
                          child: !_isImageSource(avatar)
                              ? Text(
                                  name.characters.first.toUpperCase(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 19,
                                  ),
                                )
                              : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '@${username.isNotEmpty ? username : 'user'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFA8A8A8),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 7),
                              PopupMenuButton<String>(
                                initialValue: visibility,
                                onSelected: (value) {
                                  setState(() => visibility = value);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'public',
                                    child: Row(
                                      children: [
                                        Icon(Icons.public, size: 19),
                                        SizedBox(width: 10),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text('Public'),
                                            Text(
                                              'Anyone can see this post',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'private',
                                    child: Row(
                                      children: [
                                        Icon(Icons.lock_outline, size: 19),
                                        SizedBox(width: 10),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text('Private'),
                                            Text(
                                              'Only you can see this post',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF262626),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        visibility == 'public'
                                            ? Icons.public
                                            : Icons.lock_outline,
                                        size: 14,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        visibility == 'public'
                                            ? 'Public'
                                            : 'Private',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                      const Icon(
                                        Icons.arrow_drop_down,
                                        size: 17,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
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
                    color: Colors.white,
                    fontSize: 23,
                    height: 1.35,
                  ),
                  decoration: const InputDecoration(
                    hintText: "What's on your mind?",
                    hintStyle: TextStyle(
                      color: Color(0xFFA8A8A8),
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
                                    color: const Color(0xFF262626),
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
                color: igBlack,
                border: Border.all(color: const Color(0xFF363636)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Add to your post',
                      style: TextStyle(
                        color: Colors.white,
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
                    tooltip: 'Music',
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Music selection is not available yet.',
                          ),
                        ),
                      );
                    },
                    icon: const Icon(
                      Icons.music_note_rounded,
                      color: Color(0xFF0095F6),
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
  final Map<String, Future<Uint8List?>> _thumbnailFutures = {};

  @override
  void initState() {
    super.initState();
    for (final asset in widget.assets) {
      _thumbnailFutures.putIfAbsent(
        asset.id,
        () => asset.thumbnailDataWithSize(const ThumbnailSize(220, 220)),
      );
    }
  }

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
          subtitle: Text(
            chosen.any((asset) => asset.type == AssetType.video)
                ? '1/1 video selected'
                : '${chosen.where((asset) => asset.type == AssetType.image).length}/10 photos selected',
          ),
          trailing: TextButton(
            onPressed: () => Navigator.pop(context, chosen.toList()),
            child: const Text('Done'),
          ),
        ),
        Expanded(
          child: GridView.builder(
            key: const PageStorageKey<String>('twice-media-picker-grid'),
            padding: const EdgeInsets.all(4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 3,
              mainAxisSpacing: 3,
            ),
            itemCount: widget.assets.length,
            itemBuilder: (_, i) {
              final asset = widget.assets[i];
              final isChosen = chosen.contains(asset);
              return InkWell(
                key: ValueKey<String>(asset.id),
                onTap: () {
                  if (isChosen) {
                    setState(() => chosen.remove(asset));
                    return;
                  }

                  final hasVideo = chosen.any(
                    (item) => item.type == AssetType.video,
                  );
                  final isVideo = asset.type == AssetType.video;
                  final photoCount = chosen
                      .where((item) => item.type == AssetType.image)
                      .length;

                  if (isVideo && chosen.isNotEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Choose either 10 photos or 1 video per post.',
                        ),
                      ),
                    );
                    return;
                  }

                  if (!isVideo && hasVideo) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Remove the video before selecting photos.',
                        ),
                      ),
                    );
                    return;
                  }

                  if (!isVideo && photoCount >= 10) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('You can select up to 10 photos.'),
                      ),
                    );
                    return;
                  }

                  setState(() => chosen.add(asset));
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FutureBuilder<Uint8List?>(
                      future: _thumbnailFutures[asset.id],
                      builder: (_, snapshot) {
                        final bytes = snapshot.data;
                        if (bytes == null || bytes.isEmpty) {
                          return const ColoredBox(color: canvas);
                        }
                        return Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.low,
                          errorBuilder: (_, _, _) =>
                              const ColoredBox(color: canvas),
                        );
                      },
                    ),
                    if (asset.type == AssetType.video)
                      const Positioned(
                        right: 4,
                        bottom: 4,
                        child: Icon(
                          Icons.play_circle_fill,
                          color: Colors.white,
                          shadows: [Shadow(blurRadius: 4)],
                        ),
                      ),
                    if (isChosen)
                      const Positioned(
                        top: 4,
                        right: 4,
                        child: Icon(
                          Icons.check_circle,
                          color: violet,
                          shadows: [Shadow(blurRadius: 3)],
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
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  SEARCH + PUBLIC PROFILES
// ═══════════════════════════════════════════════════════════════════════════

int _asInt(dynamic v) =>
    v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0);

String _compactCount(int n) {
  String trim(double v) {
    final s = v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (n >= 1000000) return '${trim(n / 1000000)}M';
  if (n >= 1000) return '${trim(n / 1000)}K';
  return '$n';
}

String _searchError(Object e) {
  final t = e.toString().toLowerCase();
  if (t.contains('socket') ||
      t.contains('host lookup') ||
      t.contains('timeout') ||
      t.contains('clientexception') ||
      t.contains('connection')) {
    return 'Check your connection and try again.';
  }
  return 'Something went wrong. Please try again.';
}

/// Opens any user's profile. Used everywhere a name, @username or profile
/// picture is shown.
Future<void> _openUserProfile(
  BuildContext context, {
  required String userId,
  Map<String, dynamic>? profile,
}) async {
  final id = userId.trim();
  if (id.isEmpty || id == 'null') return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => UserProfilePage(userId: id, initialProfile: profile),
    ),
  );
}

class _UserAvatar extends StatelessWidget {
  const _UserAvatar({required this.url, required this.name, this.size = 54});
  final String url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final src = url.trim();
    final has = _isImageSource(src);
    final letter = name.trim().isEmpty ? '' : name.trim()[0].toUpperCase();
    Widget fallback() => DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF262626), Color(0xFF262626)],
        ),
      ),
      child: Center(
        child: letter.isEmpty
            ? Icon(Icons.person_rounded, color: violet, size: size * 0.5)
            : Text(
                letter,
                style: TextStyle(
                  color: violet,
                  fontWeight: FontWeight.w900,
                  fontSize: size * 0.4,
                ),
              ),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: has
            ? Image(
                image: _twiceAvatarProvider(src),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback(),
              )
            : fallback(),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});
  final Widget child;
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: 0.45, end: 1).animate(_c),
    child: widget.child,
  );
}

class _SkeletonPeople extends StatelessWidget {
  const _SkeletonPeople();
  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: const Color(0xFF262626),
        borderRadius: BorderRadius.circular(8),
      ),
    );
    return _Pulse(
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
        itemCount: 7,
        itemBuilder: (_, _) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: igSurface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: const BoxDecoration(
                  color: Color(0xFF262626),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bar(120, 13),
                    const SizedBox(height: 8),
                    bar(80, 11),
                    const SizedBox(height: 8),
                    bar(150, 10),
                  ],
                ),
              ),
              bar(78, 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid({this.columns = 3, this.aspect = 1});
  final int columns;
  final double aspect;
  @override
  Widget build(BuildContext context) => _Pulse(
    child: GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: aspect,
      ),
      itemCount: columns * 4,
      itemBuilder: (_, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF262626),
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    ),
  );
}

class _SearchEmpty extends StatelessWidget {
  const _SearchEmpty({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 78,
            height: 78,
            decoration: const BoxDecoration(
              color: Color(0xFF262626),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 36, color: violet),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted, height: 1.4),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: violet,
                shape: const StadiumBorder(),
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.trailing, this.onTrailing});
  final String title;
  final String? trailing;
  final VoidCallback? onTrailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 14, 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: ink,
            ),
          ),
        ),
        if (trailing != null)
          TextButton(
            onPressed: onTrailing,
            style: TextButton.styleFrom(
              foregroundColor: violet,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(
              trailing!,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
      ],
    ),
  );
}

/// Square thumbnail of a post (photo, video poster or caption card).
class _PostThumb extends StatelessWidget {
  const _PostThumb({required this.post});
  final SocialPost post;

  @override
  Widget build(BuildContext context) {
    final media = post.media;
    final first = media.isEmpty ? null : media.first;
    final isVideo =
        first != null &&
        (first['media_type'] ?? '').toString().toLowerCase() == 'video';
    var src = '';
    if (first != null) {
      final thumb = (first['resolved_thumbnail_url'] ?? '').toString();
      final full = (first['resolved_url'] ?? '').toString();
      if (_isImageSource(thumb)) {
        src = thumb;
      } else if (!isVideo && _isImageSource(full)) {
        src = full;
      }
    }
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isVideo
              ? const [Color(0xFF262626), Color(0xFF121212)]
              : const [Color(0xFF262626), Color(0xFF363636)],
        ),
      ),
      child: media.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(10),
              child: Center(
                child: Text(
                  post.caption.isEmpty ? 'Post' : post.caption,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
            )
          : null,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (src.isNotEmpty)
          Image(
            image: _twiceImageProvider(src, maxDimension: 480),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          )
        else
          placeholder,
        if (isVideo)
          const Positioned(
            top: 7,
            right: 7,
            child: Icon(
              Icons.play_circle_fill_rounded,
              color: Colors.white,
              size: 22,
              shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
            ),
          )
        else if (media.length > 1)
          const Positioned(
            top: 7,
            right: 7,
            child: Icon(
              Icons.collections_rounded,
              color: Colors.white,
              size: 19,
              shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
            ),
          ),
      ],
    );
  }
}

class _MediaGridTile extends StatelessWidget {
  const _MediaGridTile({
    required this.post,
    required this.onTap,
    this.showAuthor = false,
  });
  final SocialPost post;
  final VoidCallback onTap;
  final bool showAuthor;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: ClipRRect(
      borderRadius: BorderRadius.zero,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _PostThumb(post: post),
          if (showAuthor)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xB3000000)],
                  ),
                ),
                child: Row(
                  children: [
                    _UserAvatar(
                      url: post.avatarUrl ?? '',
                      name: post.name,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        post.handle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.favorite_rounded,
                      color: Colors.white,
                      size: 12,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _compactCount(post.likes),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
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

enum _SearchTab { people, posts, videos, photos }

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final controller = TextEditingController();
  final focus = FocusNode();
  Timer? _debounce;
  int _requestId = 0;

  _SearchTab tab = _SearchTab.people;
  List<Map<String, dynamic>> people = [];
  List<Map<String, dynamic>> recents = [];
  List<Map<String, dynamic>> suggested = [];
  List<SocialPost> posts = [];
  bool loading = true;
  String? error;

  String get query => controller.text.trim();

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    setState(() {});
    _debounce?.cancel();
    if (query.isEmpty) {
      _run();
    } else {
      _debounce = Timer(const Duration(milliseconds: 350), _run);
    }
  }

  void _selectTab(_SearchTab next) {
    if (next == tab) return;
    setState(() {
      tab = next;
      posts = [];
      error = null;
    });
    _run();
  }

  Future<void> _run({bool silent = false}) async {
    final id = ++_requestId;
    final q = query;
    final current = tab;
    final repo = SocialRepository.instance;
    if (!silent && mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      if (current == _SearchTab.people) {
        if (q.isEmpty) {
          final results = await Future.wait<List<Map<String, dynamic>>>([
            repo.recentSearchProfiles(),
            repo.suggestedPeople(),
          ]);
          if (!mounted || id != _requestId) return;
          setState(() {
            recents = results[0];
            suggested = results[1];
            loading = false;
          });
        } else {
          final found = await repo.searchPeople(q);
          if (!mounted || id != _requestId) return;
          setState(() {
            people = found;
            loading = false;
          });
        }
      } else {
        final kind = current == _SearchTab.videos
            ? 'videos'
            : current == _SearchTab.photos
            ? 'photos'
            : 'all';
        final rows = await repo.searchPosts(q, kind: kind);
        if (!mounted || id != _requestId) return;
        setState(() {
          posts = rows.map(SocialPost.new).toList();
          loading = false;
        });
      }
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        error = _searchError(e);
        loading = false;
      });
    }
  }

  Future<void> _openProfile(Map<String, dynamic> user) async {
    unawaited(
      SocialRepository.instance
          .addRecentSearchProfile(user)
          .catchError((Object _) {}),
    );
    await _openUserProfile(
      context,
      userId: (user['id'] ?? '').toString(),
      profile: user,
    );
    if (mounted) _run(silent: true);
  }

  Future<void> _openPost(SocialPost post) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => PostDetailPage(post: post)));
    if (mounted) setState(() {});
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
    child: Container(
      decoration: BoxDecoration(
        color: igElevated,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF363636)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x00000000),
            blurRadius: 16,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        focusNode: focus,
        onChanged: _onChanged,
        onSubmitted: (_) {
          _debounce?.cancel();
          _run();
        },
        textInputAction: TextInputAction.search,
        autocorrect: false,
        cursorColor: violet,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
        decoration: InputDecoration(
          hintText: switch (tab) {
            _SearchTab.people => 'Search people by name or @username',
            _SearchTab.posts => 'Search posts',
            _SearchTab.videos => 'Search videos',
            _SearchTab.photos => 'Search photos',
          },
          hintStyle: const TextStyle(
            color: muted,
            fontSize: 15.5,
            fontWeight: FontWeight.w500,
          ),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 15),
          prefixIcon: const Icon(Icons.search_rounded, color: muted, size: 24),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  onPressed: () {
                    controller.clear();
                    _onChanged('');
                  },
                  icon: const Icon(Icons.cancel_rounded, color: muted),
                ),
        ),
      ),
    ),
  );

  Widget _tabs() {
    Widget chip(_SearchTab value, String label) {
      final active = tab == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => _selectTab(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? violet : igElevated,
              borderRadius: BorderRadius.circular(19),
              border: Border.all(
                color: active ? violet : const Color(0xFF363636),
              ),
              boxShadow: active
                  ? const [
                      BoxShadow(
                        color: Color(0x330095F6),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: active ? Colors.white : ink,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          chip(_SearchTab.people, 'People'),
          const SizedBox(width: 7),
          chip(_SearchTab.posts, 'Posts'),
          const SizedBox(width: 7),
          chip(_SearchTab.videos, 'Videos'),
          const SizedBox(width: 7),
          chip(_SearchTab.photos, 'Photos'),
        ],
      ),
    );
  }

  Widget _errorPanel() => _SearchEmpty(
    icon: Icons.cloud_off_rounded,
    title: 'Could not load results',
    subtitle: error ?? '',
    actionLabel: 'Try again',
    onAction: _run,
  );

  Widget _peopleBody() {
    final q = query;
    if (error != null && (q.isEmpty ? suggested.isEmpty : people.isEmpty)) {
      return _errorPanel();
    }
    if (q.isEmpty) {
      if (loading && recents.isEmpty && suggested.isEmpty) {
        return const _SkeletonPeople();
      }
      if (recents.isEmpty && suggested.isEmpty) {
        return const _SearchEmpty(
          icon: Icons.people_alt_rounded,
          title: 'Find people on Twice',
          subtitle: 'Search by name or @username to follow friends.',
        );
      }
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (recents.isNotEmpty) ...[
            _SectionHeader(
              'Recent',
              trailing: 'Clear all',
              onTrailing: () async {
                setState(() => recents = []);
                await SocialRepository.instance.clearRecentSearchProfiles();
              },
            ),
            for (final user in recents)
              _RecentTile(
                key: ValueKey('recent-${user['id']}'),
                user: user,
                onOpen: () => _openProfile(user),
                onRemove: () async {
                  setState(() => recents.remove(user));
                  await SocialRepository.instance.removeRecentSearchProfile(
                    user['id'].toString(),
                  );
                },
              ),
          ],
          if (suggested.isNotEmpty) ...[
            const _SectionHeader('Suggested for you'),
            for (final user in suggested)
              _PersonTile(
                key: ValueKey('suggested-${user['id']}'),
                user: user,
                onOpen: () => _openProfile(user),
              ),
          ],
        ],
      );
    }
    if (loading && people.isEmpty) return const _SkeletonPeople();
    if (people.isEmpty) {
      return _SearchEmpty(
        icon: Icons.person_search_rounded,
        title: 'No people found',
        subtitle:
            'We couldn’t find anyone matching “$q”.\nCheck the spelling or try another name.',
      );
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 24, top: 2),
      itemCount: people.length,
      itemBuilder: (_, i) => _PersonTile(
        key: ValueKey('person-${people[i]['id']}'),
        user: people[i],
        onOpen: () => _openProfile(people[i]),
      ),
    );
  }

  Widget _postsBody() {
    final q = query;
    if (error != null && posts.isEmpty) return _errorPanel();
    final isVideos = tab == _SearchTab.videos;
    final isPhotos = tab == _SearchTab.photos;
    if (loading && posts.isEmpty) {
      return isVideos
          ? const _SkeletonGrid(columns: 2, aspect: 0.72)
          : isPhotos
          ? const _SkeletonGrid()
          : q.isEmpty
          ? const _SkeletonGrid()
          : const _SkeletonPeople();
    }
    final label = isVideos
        ? 'videos'
        : isPhotos
        ? 'photos'
        : 'posts';
    if (posts.isEmpty) {
      return _SearchEmpty(
        icon: isVideos
            ? Icons.play_circle_outline_rounded
            : isPhotos
            ? Icons.photo_library_outlined
            : Icons.article_outlined,
        title: q.isEmpty ? 'No $label yet' : 'No $label found',
        subtitle: q.isEmpty
            ? 'New $label from the community will show up here.'
            : 'Nothing matches “$q”. Try different words.',
      );
    }

    // Posts tab with a query → rich result cards.
    if (tab == _SearchTab.posts && q.isNotEmpty) {
      return ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 24),
        itemCount: posts.length,
        itemBuilder: (_, i) =>
            _PostResultTile(post: posts[i], onTap: () => _openPost(posts[i])),
      );
    }

    // Grids: explore (posts, empty query), videos and photos.
    final items = tab == _SearchTab.posts
        ? posts.where((p) => p.media.isNotEmpty).toList()
        : posts;
    final cols = isVideos ? 2 : 3;
    final title = q.isEmpty
        ? (isVideos
              ? 'Trending videos'
              : isPhotos
              ? 'Latest photos'
              : 'Explore')
        : 'Results for “$q”';
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(child: _SectionHeader(title)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 24),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: isVideos ? 0.72 : 1,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) => _MediaGridTile(
                post: items[i],
                showAuthor: isVideos,
                onTap: () => _openPost(items[i]),
              ),
              childCount: items.length,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      children: [
        _searchField(),
        _tabs(),
        if (loading && (people.isNotEmpty || posts.isNotEmpty))
          const SizedBox(
            height: 2,
            child: LinearProgressIndicator(
              color: violet,
              backgroundColor: Colors.transparent,
            ),
          )
        else
          const SizedBox(height: 2),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: KeyedSubtree(
              key: ValueKey('${tab.name}-${query.isEmpty}'),
              child: tab == _SearchTab.people ? _peopleBody() : _postsBody(),
            ),
          ),
        ),
      ],
    ),
  );
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    super.key,
    required this.user,
    required this.onOpen,
    required this.onRemove,
  });
  final Map<String, dynamic> user;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final username = (user['username'] ?? '').toString();
    final name = (user['display_name'] ?? '').toString().trim();
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 7, 6, 7),
        child: Row(
          children: [
            _UserAvatar(
              url: (user['avatar_url'] ?? '').toString(),
              name: name.isEmpty ? username : name,
              size: 46,
            ),
            const SizedBox(width: 12),
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
                      fontSize: 14.5,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '@$username',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, color: muted, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonTile extends StatefulWidget {
  const _PersonTile({super.key, required this.user, required this.onOpen});
  final Map<String, dynamic> user;
  final Future<void> Function() onOpen;
  @override
  State<_PersonTile> createState() => _PersonTileState();
}

class _PersonTileState extends State<_PersonTile> {
  bool busy = false;

  String get label => (widget.user['follow_label'] ?? '').toString();

  Future<void> _toggle() async {
    if (busy) return;
    final user = widget.user;
    final id = (user['id'] ?? '').toString();
    final previous = label;
    final repo = SocialRepository.instance;
    setState(() => busy = true);
    try {
      if (previous == 'Following' || previous == 'Requested') {
        await repo.unfollow(id);
        user['follow_label'] = 'Follow';
        if (previous == 'Following') {
          user['followers_count'] = max(0, _asInt(user['followers_count']) - 1);
        }
      } else {
        final priv = user['is_private'] == true;
        await repo.follow(id, privateAccount: priv);
        user['follow_label'] = priv ? 'Requested' : 'Following';
        if (!priv) {
          user['followers_count'] = _asInt(user['followers_count']) + 1;
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Follow action failed: $e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _followButton() {
    final current = label;
    if (current.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF262626),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'You',
          style: TextStyle(
            color: violet,
            fontWeight: FontWeight.w800,
            fontSize: 12.5,
          ),
        ),
      );
    }
    final outlined = current == 'Following' || current == 'Requested';
    final child = busy
        ? SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: outlined ? violet : Colors.white,
            ),
          )
        : Text(
            current,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          );
    final shape = const StadiumBorder();
    return SizedBox(
      height: 34,
      width: 94,
      child: outlined
          ? OutlinedButton(
              onPressed: busy ? null : _toggle,
              style: OutlinedButton.styleFrom(
                foregroundColor: current == 'Requested' ? muted : ink,
                side: const BorderSide(color: Color(0xFF363636)),
                padding: EdgeInsets.zero,
                shape: shape,
              ),
              child: child,
            )
          : FilledButton(
              onPressed: busy ? null : _toggle,
              style: FilledButton.styleFrom(
                backgroundColor: violet,
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                shape: shape,
              ),
              child: child,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final username = (user['username'] ?? 'user').toString();
    final name = (user['display_name'] ?? '').toString().trim();
    final followers = _asInt(user['followers_count']);
    final following = _asInt(user['following_count']);
    const numStyle = TextStyle(fontWeight: FontWeight.w800, color: ink);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Material(
        color: igBlack,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF363636)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              children: [
                _UserAvatar(
                  url: (user['avatar_url'] ?? '').toString(),
                  name: name.isEmpty ? username : name,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name.isEmpty ? username : name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                color: ink,
                              ),
                            ),
                          ),
                          if (user['is_private'] == true) ...[
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.lock_rounded,
                              size: 13,
                              color: muted,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '@$username',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted, fontSize: 13),
                      ),
                      const SizedBox(height: 5),
                      Text.rich(
                        TextSpan(
                          style: const TextStyle(color: muted, fontSize: 11.5),
                          children: [
                            TextSpan(
                              text: _compactCount(followers),
                              style: numStyle,
                            ),
                            TextSpan(
                              text: followers == 1
                                  ? ' follower   '
                                  : ' followers   ',
                            ),
                            TextSpan(
                              text: _compactCount(following),
                              style: numStyle,
                            ),
                            const TextSpan(text: ' following'),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _followButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PostResultTile extends StatelessWidget {
  const _PostResultTile({required this.post, required this.onTap});
  final SocialPost post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: igBlack,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF363636)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (post.media.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 82,
                    height: 82,
                    child: _PostThumb(post: post),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openUserProfile(
                        context,
                        userId: (post.author['id'] ?? '').toString(),
                        profile: post.author,
                      ),
                      child: Row(
                        children: [
                          _UserAvatar(
                            url: post.avatarUrl ?? '',
                            name: post.name,
                            size: 22,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: post.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: ink,
                                    ),
                                  ),
                                  TextSpan(
                                    text: '  ${post.handle}',
                                    style: const TextStyle(color: muted),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      post.caption.isEmpty ? 'Media post' : post.caption,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(
                          Icons.favorite_rounded,
                          size: 14,
                          color: Color(0xFFFF3040),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _compactCount(post.likes),
                          style: const TextStyle(
                            color: muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Icon(
                          Icons.chat_bubble_rounded,
                          size: 13,
                          color: muted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _compactCount(post.commentCount),
                          style: const TextStyle(
                            color: muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _timeAgo(post.data['created_at']),
                          style: const TextStyle(color: muted, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A single post opened from search or a profile grid.
class PostDetailPage extends StatefulWidget {
  const PostDetailPage({
    super.key,
    required this.post,
    this.authorTappable = true,
    this.openCommentsOnOpen = false,
  });
  final SocialPost post;
  final bool authorTappable;
  final bool openCommentsOnOpen;
  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  @override
  void initState() {
    super.initState();
    if (widget.openCommentsOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => CommentsSheet(post: widget.post),
        );
      });
    }
  }

  Future<void> _like(SocialPost item) async {
    final wasLiked = item.liked;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    final before = List<Map<String, dynamic>>.from(
      (item.data['post_likes'] as List? ?? const []).whereType<Map>().map(
        (e) => Map<String, dynamic>.from(e),
      ),
    );
    final rows = List<Map<String, dynamic>>.from(before);
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
      if (!mounted) return;
      setState(() => item.data['post_likes'] = before);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Like failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: canvas,
    appBar: AppBar(
      backgroundColor: canvas,
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      title: const Text(
        'Post',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
      children: [
        PostCard(
          post: widget.post,
          authorTappable: widget.authorTappable,
          onLike: _like,
          onCommentChanged: () {
            if (mounted) setState(() {});
          },
        ),
      ],
    ),
  );
}

class _ProfileTabsDelegate extends SliverPersistentHeaderDelegate {
  _ProfileTabsDelegate({required this.child, this.extent = 52});
  final Widget child;
  final double extent;
  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox.expand(child: child);
  @override
  bool shouldRebuild(covariant _ProfileTabsDelegate oldDelegate) => true;
}

/// Instagram-style profile header: avatar on the left, Posts / Followers /
/// Following on the right, name + bio underneath and a row of action buttons.
class _IgProfileHeader extends StatelessWidget {
  const _IgProfileHeader({
    required this.avatar,
    required this.name,
    required this.bio,
    required this.isPrivate,
    required this.posts,
    required this.followers,
    required this.following,
    required this.onFollowers,
    required this.onFollowing,
    required this.actions,
  });

  final String avatar;
  final String name;
  final String bio;
  final bool isPrivate;
  final String posts;
  final String followers;
  final String following;
  final VoidCallback? onFollowers;
  final VoidCallback? onFollowing;
  final List<Widget> actions;

  Widget _stat(String value, String label, VoidCallback? onTap) => Expanded(
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: ink, fontSize: 13)),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _UserAvatar(url: avatar, name: name, size: 86),
            const SizedBox(width: 18),
            Expanded(
              child: Row(
                children: [
                  _stat(posts, 'Posts', null),
                  _stat(followers, 'Followers', onFollowers),
                  _stat(following, 'Following', onFollowing),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Flexible(
              child: Text(
                name.isEmpty ? ' ' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
            ),
            if (isPrivate) ...[
              const SizedBox(width: 6),
              const Icon(Icons.lock_outline_rounded, size: 14, color: muted),
            ],
          ],
        ),
        if (bio.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(
              style: const TextStyle(color: ink, fontSize: 14, height: 1.3),
              children: _captionSpans(bio),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Row(children: actions),
      ],
    ),
  );
}

/// Flat Instagram profile button: #262626, or blue when it is the main action.
class _IgProfileButton extends StatelessWidget {
  const _IgProfileButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    child: FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: primary ? igBlue : igElevated,
        disabledBackgroundColor: primary ? igBlue : igElevated,
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
    ),
  );
}

/// Icon-only tab (grid / photos / videos) with a white underline when active.
Widget _igProfileTab({
  required IconData icon,
  required bool active,
  required VoidCallback onTap,
}) => Expanded(
  child: InkWell(
    onTap: onTap,
    child: Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: active ? Colors.white : Colors.transparent,
            width: 1.5,
          ),
        ),
      ),
      child: Icon(icon, size: 26, color: active ? Colors.white : muted),
    ),
  ),
);

/// Public profile of any Twice user: header, follow / message actions,
/// followers + following lists and all their posts, photos and videos.
class UserProfilePage extends StatefulWidget {
  const UserProfilePage({super.key, required this.userId, this.initialProfile});
  final String userId;
  final Map<String, dynamic>? initialProfile;
  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  Map<String, dynamic> profile = {};
  int followers = 0, following = 0, postCount = 0;
  bool statsLoaded = false;
  bool profileLoading = true;
  bool postsLoading = true;
  bool notFound = false;
  String? postsError;
  List<SocialPost> posts = [];
  String followLabel = '';
  bool labelLoaded = false;
  bool followBusy = false;
  bool messageBusy = false;
  int tab = 0;

  bool get isSelf =>
      widget.userId == Supabase.instance.client.auth.currentUser?.id;

  bool get isPrivate => profile['is_private'] == true;

  bool get isFollowing =>
      followLabel == 'Following' || followLabel == 'Connected';

  bool get locked =>
      isPrivate && !isSelf && labelLoaded && !isFollowing && posts.isEmpty;

  String get username => (profile['username'] ?? '').toString();
  String get displayName => (profile['display_name'] ?? '').toString().trim();
  String get shownName => displayName.isEmpty ? username : displayName;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialProfile;
    if (initial != null) {
      profile = Map<String, dynamic>.from(initial);
      if (initial.containsKey('followers_count')) {
        followers = _asInt(initial['followers_count']);
        following = _asInt(initial['following_count']);
      }
    }
    _load();
  }

  Future<void> _load() async {
    await Future.wait<void>([
      _loadProfile(),
      _loadStats(),
      _loadFollowLabel(),
      _loadPosts(),
    ]);
  }

  Future<void> _loadProfile() async {
    try {
      final fresh = await SocialRepository.instance.profileById(widget.userId);
      if (!mounted) return;
      setState(() {
        if (fresh == null) {
          notFound = profile.isEmpty;
        } else {
          final oldAvatar = (profile['avatar_url'] ?? '').toString();
          profile = fresh;
          if ((fresh['avatar_url'] ?? '').toString().isEmpty &&
              oldAvatar.isNotEmpty) {
            profile['avatar_url'] = oldAvatar;
          }
        }
        profileLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => profileLoading = false);
    }
  }

  Future<void> _loadStats() async {
    try {
      final stats = await SocialRepository.instance.profileStats(widget.userId);
      if (!mounted) return;
      setState(() {
        followers = stats['followers'] ?? 0;
        following = stats['following'] ?? 0;
        postCount = stats['posts'] ?? 0;
        statsLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => statsLoaded = true);
    }
  }

  Future<void> _loadFollowLabel() async {
    try {
      final label = await SocialRepository.instance.getFollowLabel(
        widget.userId,
      );
      if (!mounted) return;
      setState(() {
        followLabel = label;
        labelLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => labelLoaded = true);
    }
  }

  Future<void> _loadPosts() async {
    try {
      final rows = await SocialRepository.instance.userPosts(widget.userId);
      if (!mounted) return;
      setState(() {
        posts = rows.map(SocialPost.new).toList();
        postsLoading = false;
        postsError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        postsLoading = false;
        postsError = _searchError(e);
      });
    }
  }

  Future<void> _toggleFollow() async {
    if (followBusy || isSelf) return;
    final repo = SocialRepository.instance;
    final previous = followLabel;
    setState(() => followBusy = true);
    try {
      if (previous == 'Following' ||
          previous == 'Connected' ||
          previous == 'Requested') {
        await repo.unfollow(widget.userId);
        setState(() {
          followLabel = 'Follow';
          if (previous != 'Requested') followers = max(0, followers - 1);
        });
      } else {
        final priv = await repo.isPrivateAccount(widget.userId);
        await repo.follow(widget.userId, privateAccount: priv);
        setState(() {
          followLabel = priv ? 'Requested' : 'Following';
          if (!priv) followers += 1;
        });
      }
      await Future.wait<void>([_loadFollowLabel(), _loadStats(), _loadPosts()]);
    } catch (e) {
      if (mounted) {
        setState(() => followLabel = previous);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not update follow: $e')));
      }
    } finally {
      if (mounted) setState(() => followBusy = false);
    }
  }

  Future<void> _message() async {
    if (messageBusy || isSelf) return;
    setState(() => messageBusy = true);
    try {
      final id = await SocialRepository.instance.createConversation(
        widget.userId,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationPage(
            id: id,
            title: shownName.isEmpty ? 'Message' : shownName,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start conversation: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => messageBusy = false);
    }
  }

  Future<void> _copyLink() async {
    if (username.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: 'https://twice.app/@$username'),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Profile link copied')));
  }

  void _openFollowList(bool showFollowers) {
    if (locked) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            FollowListPage(profileId: widget.userId, followers: showFollowers),
      ),
    );
  }

  Future<void> _openPost(SocialPost post) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PostDetailPage(post: post, authorTappable: false),
      ),
    );
    if (mounted) setState(() {});
  }

  bool _isPhoto(SocialPost p) => p.media.any((m) {
    final t = (m['media_type'] ?? '').toString().toLowerCase();
    return t == 'image' || t == 'gif';
  });

  bool _isVideo(SocialPost p) => p.media.any(
    (m) => (m['media_type'] ?? '').toString().toLowerCase() == 'video',
  );

  List<SocialPost> get _visible => tab == 1
      ? posts.where(_isPhoto).toList()
      : tab == 2
      ? posts.where(_isVideo).toList()
      : posts;

  Widget _followButton() {
    final label = !labelLoaded
        ? 'Follow'
        : followLabel.isEmpty
        ? 'Follow'
        : isFollowing
        ? 'Following'
        : followLabel;
    final outlined = label == 'Following' || label == 'Requested';
    return _IgProfileButton(
      label: label,
      primary: !outlined,
      busy: followBusy,
      onPressed: !labelLoaded ? null : _toggleFollow,
    );
  }

  Widget _header() {
    final avatar = (profile['avatar_url'] ?? '').toString();
    final bio = (profile['bio'] ?? '').toString().trim();
    return _IgProfileHeader(
      avatar: avatar,
      name: shownName,
      bio: bio,
      isPrivate: isPrivate,
      posts: statsLoaded ? _compactCount(postCount) : '…',
      followers: statsLoaded || followers > 0 ? _compactCount(followers) : '…',
      following: statsLoaded || following > 0 ? _compactCount(following) : '…',
      onFollowers: () => _openFollowList(true),
      onFollowing: () => _openFollowList(false),
      actions: isSelf
          ? [
              Expanded(
                child: _IgProfileButton(
                  label: 'This is your profile',
                  onPressed: () {},
                ),
              ),
            ]
          : [
              Expanded(child: _followButton()),
              const SizedBox(width: 8),
              Expanded(
                child: _IgProfileButton(
                  label: 'Message',
                  busy: messageBusy,
                  onPressed: _message,
                ),
              ),
            ],
    );
  }

  Widget _tabBar() {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: canvas,
        border: Border(bottom: BorderSide(color: igBorder, width: 0.5)),
      ),
      child: Row(
        children: [
          _igProfileTab(
            icon: Icons.grid_on_rounded,
            active: tab == 0,
            onTap: () => setState(() => tab = 0),
          ),
          _igProfileTab(
            icon: Icons.photo_outlined,
            active: tab == 1,
            onTap: () => setState(() => tab = 1),
          ),
          _igProfileTab(
            icon: Icons.play_circle_outline_rounded,
            active: tab == 2,
            onTap: () => setState(() => tab = 2),
          ),
        ],
      ),
    );
  }

  Widget _emptyBox(IconData icon, String title, String subtitle) => SizedBox(
    height: 300,
    child: _SearchEmpty(icon: icon, title: title, subtitle: subtitle),
  );

  List<Widget> _content() {
    if (notFound) {
      return [
        SliverToBoxAdapter(
          child: _emptyBox(
            Icons.person_off_rounded,
            'Profile not available',
            'This account doesn’t exist or can’t be shown.',
          ),
        ),
      ];
    }
    if (locked) {
      return [
        SliverToBoxAdapter(
          child: _emptyBox(
            Icons.lock_rounded,
            'This account is private',
            'Follow ${shownName.isEmpty ? 'this account' : shownName} to see their posts, photos and videos.',
          ),
        ),
      ];
    }
    if (postsLoading && posts.isEmpty) {
      return [
        SliverPadding(
          padding: EdgeInsets.zero,
          sliver: SliverToBoxAdapter(
            child: SizedBox(
              height: 330,
              child: _Pulse(
                child: GridView.count(
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 3,
                  mainAxisSpacing: 1.5,
                  crossAxisSpacing: 1.5,
                  children: List.generate(
                    9,
                    (_) => DecoratedBox(
                      decoration: const BoxDecoration(color: Color(0xFF262626)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ];
    }
    if (postsError != null && posts.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 300,
            child: _SearchEmpty(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load posts',
              subtitle: postsError!,
              actionLabel: 'Try again',
              onAction: _loadPosts,
            ),
          ),
        ),
      ];
    }
    final items = _visible;
    if (items.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _emptyBox(
            tab == 2
                ? Icons.play_circle_outline_rounded
                : tab == 1
                ? Icons.photo_library_outlined
                : Icons.grid_on_rounded,
            tab == 2
                ? 'No videos yet'
                : tab == 1
                ? 'No photos yet'
                : 'No posts yet',
            isSelf
                ? 'Share a moment and it will appear here.'
                : '${shownName.isEmpty ? 'This user' : shownName} hasn’t shared anything here yet.',
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.zero,
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 1.5,
            crossAxisSpacing: 1.5,
            childAspectRatio: tab == 2 ? 0.72 : 1,
          ),
          delegate: SliverChildBuilderDelegate(
            (_, i) => _MediaGridTile(
              post: items[i],
              onTap: () => _openPost(items[i]),
            ),
            childCount: items.length,
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: canvas,
      body: RefreshIndicator(
        color: violet,
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: canvas,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: IconButton(
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              title: Text(
                username.isEmpty ? 'Profile' : username,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              actions: [
                IconButton(
                  tooltip: 'Copy profile link',
                  onPressed: _copyLink,
                  icon: const Icon(Icons.ios_share_rounded),
                ),
              ],
            ),
            if (profile.isEmpty && profileLoading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator(color: violet)),
              )
            else ...[
              if (!notFound) SliverToBoxAdapter(child: _header()),
              if (!notFound && !locked)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _ProfileTabsDelegate(child: _tabBar()),
                ),
              ..._content(),
              SliverToBoxAdapter(child: SizedBox(height: 28 + bottom)),
            ],
          ],
        ),
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
  Map<String, dynamic>? replyingTo;
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
      'id': _newTwiceUuid(),
      'post_id': widget.post.id,
      'user_id': Supabase.instance.client.auth.currentUser?.id ?? '',
      'body': text,
      if (replyingTo != null) 'parent_id': replyingTo!['id'].toString(),
      'created_at': DateTime.now().toIso8601String(),
      'profiles': <String, dynamic>{'display_name': 'You'},
      '_pending': true,
    };

    // Render immediately and clear the composer before network work begins.
    setState(() {
      rows = [...rows, optimistic];
      controller.clear();
      replyingTo = null;
      loadError = null;
      busy = false;
      sending = true;
    });

    // Persist in the background; no comments refresh or feed reload.
    try {
      final synced = await SocialRepository.instance.addComment(
        widget.post.id,
        text,
        commentId: optimistic['id'].toString(),
      );
      if (!mounted) return;
      setState(() {
        optimistic.remove('_pending');
        if (!synced) optimistic['_queued'] = true;
      });
      if (!synced) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Saved offline. This comment will sync when you reconnect.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
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
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  List<Widget> _buildCommentThread() {
    final ids = rows.map((r) => r['id']?.toString() ?? '').toSet();
    final roots = <Map<String, dynamic>>[];
    final children = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final parent = row['parent_id']?.toString() ?? '';
      if (parent.isEmpty || parent == 'null' || !ids.contains(parent)) {
        roots.add(row);
      } else {
        children.putIfAbsent(parent, () => <Map<String, dynamic>>[]).add(row);
      }
    }
    final result = <Widget>[];
    for (final row in roots) {
      result.add(_buildOneComment(row, onReply: () {
        setState(() => replyingTo = row);
      }));
      final replies = children[row['id']?.toString() ?? ''] ?? <Map<String, dynamic>>[];
      for (final reply in replies) {
        result.add(_buildOneComment(reply, isReply: true));
      }
    }
    return result;
  }

  Widget _buildOneComment(Map<String, dynamic> row, {
    bool isReply = false, VoidCallback? onReply,
  }) {
    final profile = row['profiles'] as Map? ?? {};
    final name = (profile['username'] ?? profile['display_name'] ?? 'user')
        .toString().replaceFirst(RegExp(r'^@'), '');
    return _commentRow(
      p: profile,
      userId: (profile['id'] ?? row['user_id'] ?? '').toString(),
      name: name,
      body: (row['body'] ?? '').toString(),
      time: _timeAgo(row['created_at']),
      isReply: isReply,
      onReply: isReply ? null : onReply,
      status: row['_queued'] == true
          ? const Padding(padding: EdgeInsets.only(top: 4), child: Text(
              'Saved offline · waiting to sync',
              style: TextStyle(fontSize: 11, color: muted)))
          : row['_failed'] == true
              ? const Padding(padding: EdgeInsets.only(top: 4), child: Text(
                  'Not synced · check connection and retry',
                  style: TextStyle(fontSize: 11, color: igRed)))
              : null,
    );
  }

  Widget _commentAvatar(Map p, String name, {double radius = 18}) {
    final avatar = (p['avatar_url'] ?? '').toString().trim();
    final hasAvatar =
        _isImageSource(avatar) ||
        avatar.startsWith('file://') ||
        avatar.startsWith('/');
    return CircleAvatar(
      radius: radius,
      backgroundColor: igElevated,
      backgroundImage: hasAvatar ? _twiceAvatarProvider(avatar) : null,
      child: hasAvatar
          ? null
          : Text(
              name.isNotEmpty ? name[0].toUpperCase() : 'U',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }

  Widget _commentRow({
    required Map p,
    required String userId,
    required String name,
    required String body,
    String? time,
    Widget? status,
    VoidCallback? onReply,
    bool isReply = false,
  }) {
    void openProfile() => _openUserProfile(
      context,
      userId: userId,
      profile: Map<String, dynamic>.from(p),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: 16, left: isReply ? 34 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: openProfile,
            child: _commentAvatar(p, name),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.3,
                    ),
                    children: [
                      TextSpan(
                        text: '$name ',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      ..._captionSpans(body),
                    ],
                  ),
                ),
                if (time != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    time,
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
                ?status,
                if (onReply != null) ...[
                  const SizedBox(height: 5),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onReply,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 3),
                      child: Text('Reply', style: TextStyle(
                        color: muted, fontSize: 12, fontWeight: FontWeight.w800,
                      )),
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

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final postAuthor = post.author;
    final postUsername = post.username.replaceFirst(RegExp(r'^@'), '');
    final hasText = controller.text.trim().isNotEmpty;

    Widget list() {
      if (busy) {
        return const Center(child: CircularProgressIndicator());
      }
      if (loadError != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load comments'),
                const SizedBox(height: 8),
                Text(
                  loadError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                TextButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        children: [
          // The post's own caption is shown first, like Instagram.
          if (post.caption.isNotEmpty)
            _commentRow(
              p: postAuthor,
              userId: (postAuthor['id'] ?? '').toString(),
              name: postUsername,
              body: post.caption,
              time: _timeAgo(post.data['created_at']),
            ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Column(
                children: [
                  Text(
                    'No comments yet.',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Start the conversation.',
                    style: TextStyle(color: muted, fontSize: 14),
                  ),
                ],
              ),
            ),
          ..._buildCommentThread(),
        ],
      );
    }

    return Container(
      height: MediaQuery.sizeOf(context).height * .78,
      decoration: const BoxDecoration(
        color: igSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF5A5A5A),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Comments',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          const Divider(height: 1, thickness: 0.5, color: igBorder),
          Expanded(child: list()),
          const Divider(height: 1, thickness: 0.5, color: igBorder),
          if (replyingTo != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              color: const Color(0xFF202020),
              child: Row(children: [
                Expanded(child: Text(
                  'Replying to comment: ${(replyingTo!['body'] ?? '').toString()}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 12),
                )),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => replyingTo = null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ]),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                10,
                12,
                10 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.only(left: 16, right: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0xFF363636)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller,
                              minLines: 1,
                              maxLines: 4,
                              onChanged: (_) => setState(() {}),
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                              style: const TextStyle(fontSize: 14),
                              decoration: InputDecoration(
                                hintText: replyingTo == null ? 'Add a comment for $postUsername…' : 'Reply to comment…',
                                hintStyle: const TextStyle(
                                  color: muted,
                                  fontSize: 14,
                                ),
                                filled: false,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                              ),
                            ),
                          ),
                          sending
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 14),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : TextButton(
                                  onPressed: hasText ? _send : null,
                                  child: Text(
                                    'Post',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                      color: hasText
                                          ? igBlue
                                          : const Color(0x800095F6),
                                    ),
                                  ),
                                ),
                        ],
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
}

class ActivityPage extends StatefulWidget {
  const ActivityPage({super.key, this.active = false});

  final bool active;

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  List<Map<String, dynamic>>? rows;
  String? loadError;
  Set<String> _newIds = {};
  int _seenVersion = InboxController.instance.version;
  Timer? _markTimer;

  @override
  void initState() {
    super.initState();
    InboxController.instance.addListener(_onInbox);
    if (widget.active) _activate();
  }

  @override
  void didUpdateWidget(covariant ActivityPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _activate();
    } else if (!widget.active && old.active) {
      InboxController.instance.viewing = false;
      _markTimer?.cancel();
    }
  }

  Future<void> _activate() async {
    InboxController.instance.viewing = true;
    _newIds = {};
    await _load();
    _markTimer?.cancel();
    _markTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && widget.active) InboxController.instance.markAllRead();
    });
  }

  void _onInbox() {
    if (!mounted) return;
    final v = InboxController.instance.version;
    if (v != _seenVersion) {
      _seenVersion = v;
      if (widget.active || rows != null) _load();
    }
  }

  Future<void> _load() async {
    try {
      final data = await SocialRepository.instance.inbox();
      if (!mounted) return;
      final previous = {for (final r in rows ?? const []) r['id'].toString()};
      setState(() {
        for (final r in data) {
          final id = r['id'].toString();
          if (r['is_read'] != true ||
              (previous.isNotEmpty && !previous.contains(id))) {
            _newIds.add(id);
          }
        }
        rows = data;
        loadError = null;
      });
    } catch (e) {
      if (mounted && rows == null) setState(() => loadError = e.toString());
    }
  }

  @override
  void dispose() {
    InboxController.instance.removeListener(_onInbox);
    InboxController.instance.viewing = false;
    _markTimer?.cancel();
    super.dispose();
  }

  (IconData, Color) _badgeFor(String type) {
    switch (type) {
      case 'like':
        return (Icons.favorite_rounded, const Color(0xFFFF3040));
      case 'story_reaction':
        return (Icons.favorite_rounded, const Color(0xFFFF3040));
      case 'comment':
      case 'reply':
        return (Icons.mode_comment_rounded, const Color(0xFF2F80ED));
      case 'story_reply':
      case 'message':
        return (Icons.reply_rounded, const Color(0xFF0095F6));
      default:
        return (Icons.person_add_alt_1_rounded, const Color(0xFF0095F6));
    }
  }

  String _action(Map<String, dynamic> row) {
    final comment = (row['body'] ?? row['comment_text'] ?? '')
        .toString()
        .trim();
    final quoted = comment.isEmpty ? '' : ': “$comment”';
    switch ((row['type'] ?? '').toString()) {
      case 'like':
        return 'liked your post.';
      case 'comment':
        return 'commented on your post$quoted';
      case 'reply':
        return 'replied to your comment$quoted';
      case 'follow':
        return 'started following you.';
      case 'follow_request':
        return 'requested to follow you.';
      case 'story_reaction':
        return 'liked your story.';
      case 'story_reply':
        return 'replied to your story$quoted';
      case 'message':
        return 'sent you a message.';
      default:
        return 'interacted with you.';
    }
  }

  void _openActorProfile(Map<String, dynamic> actor, String avatar) {
    final id = (actor['id'] ?? '').toString();
    if (id.isEmpty) return;
    _openUserProfile(
      context,
      userId: id,
      profile: {...actor, 'avatar_url': avatar},
    );
  }

  Future<void> _openNotificationTarget(Map<String, dynamic> row) async {
    final type = (row['type'] ?? '').toString();
    final postId = (row['post_id'] ?? '').toString().trim();
    final opensPost = {'like', 'comment', 'reply'}.contains(type);
    if (!opensPost || postId.isEmpty) {
      final actor = Map<String, dynamic>.from(
        row['profiles'] as Map? ?? const {},
      );
      _openActorProfile(actor, (row['actor_avatar'] ?? '').toString());
      return;
    }
    try {
      final data = await SocialRepository.instance.postById(postId);
      if (!mounted) return;
      if (data == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This post is no longer available.')),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PostDetailPage(
            post: SocialPost(data),
            openCommentsOnOpen: type == 'comment' || type == 'reply',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open post: $e')));
    }
  }

  Widget _tile(Map<String, dynamic> row) {
    final actor = Map<String, dynamic>.from(
      row['profiles'] as Map? ?? const {},
    );
    final name = (actor['display_name'] ?? '').toString().trim().isNotEmpty
        ? actor['display_name'].toString()
        : (actor['username'] ?? 'Someone').toString();
    final avatar = (row['actor_avatar'] ?? '').toString();
    final thumb = (row['post_thumb'] ?? '').toString();
    final isNew = _newIds.contains(row['id'].toString());
    final (icon, tint) = _badgeFor((row['type'] ?? '').toString());
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openNotificationTarget(row),
      child: Container(
        color: isNew ? const Color(0xFF262626) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openActorProfile(actor, avatar),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    radius: 25,
                    backgroundColor: const Color(0xFF262626),
                    backgroundImage: _isImageSource(avatar)
                        ? _twiceAvatarProvider(avatar)
                        : null,
                    child: _isImageSource(avatar)
                        ? null
                        : const Icon(Icons.person_rounded, color: muted),
                  ),
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: tint,
                        shape: BoxShape.circle,
                        border: Border.all(color: igBlack, width: 2),
                      ),
                      child: Icon(icon, size: 12, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: GestureDetector(
                            onTap: () => _openActorProfile(actor, avatar),
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        TextSpan(text: ' ${_action(row)}'),
                      ],
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 14.5,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _timeAgo(row['created_at']),
                    style: TextStyle(
                      color: isNew ? const Color(0xFF0095F6) : muted,
                      fontSize: 12.5,
                      fontWeight: isNew ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            if (_isImageSource(thumb)) ...[
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Image(
                    image: _twiceImageProvider(thumb, maxDimension: 200),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: Color(0xFF262626)),
                  ),
                ),
              ),
            ] else if (isNew) ...[
              const SizedBox(width: 10),
              const CircleAvatar(radius: 5, backgroundColor: Color(0xFF0095F6)),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = rows;
    if (list == null && loadError == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (list == null) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 160),
            Center(
              child: Text(
                'Could not load inbox\n$loadError',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }
    if (list.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 150),
            Icon(Icons.notifications_none_rounded, size: 64, color: muted),
            SizedBox(height: 12),
            Center(
              child: Text(
                'No notifications yet',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
            ),
            SizedBox(height: 6),
            Center(
              child: Text(
                'Likes, comments, follows and story\nreplies will show up here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted),
              ),
            ),
          ],
        ),
      );
    }
    final fresh = list
        .where((r) => _newIds.contains(r['id'].toString()))
        .toList();
    final earlier = list
        .where((r) => !_newIds.contains(r['id'].toString()))
        .toList();
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: ink,
        ),
      ),
    );
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (fresh.isNotEmpty) ...[header('New'), ...fresh.map(_tile)],
          if (earlier.isNotEmpty) ...[
            header(fresh.isEmpty ? 'Recent' : 'Earlier'),
            ...earlier.map(_tile),
          ],
        ],
      ),
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
    List<AssetEntity> photos;
    try {
      photos = await _loadSelectableMedia(size: 150);
      photos.removeWhere((asset) => asset.type != AssetType.image);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open media library: $error')),
        );
      }
      return;
    }
    if (!mounted) return;
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
    fillColor: igElevated,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Color(0xFF363636)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Color(0xFF363636)),
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
                                color: igBlack,
                                border: Border.all(
                                  color: const Color(0xFF363636),
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
                                      ? Image(
                                          image: _twiceAvatarProvider(avatar),
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
                color: igBlack,
                border: Border(top: BorderSide(color: Color(0xFF363636))),
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
  final Set<String> _busyUsers = {};
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

  Widget _followAction(Map<String, dynamic> user) {
    final id = (user['id'] ?? '').toString();
    final connected = user['is_connected'] == true;
    final followingBack = user['is_following_back'] == true;
    final busy = _busyUsers.contains(id);

    final label = connected
        ? 'Connected'
        : followingBack
        ? 'Following'
        : user['follow_request_pending'] == true
        ? 'Requested'
        : 'Follow back';

    return OutlinedButton(
      onPressed: busy || id.isEmpty || connected || followingBack
          ? null
          : () async {
              setState(() => _busyUsers.add(id));
              try {
                final repo = SocialRepository.instance;
                final privateAccount = await repo.isPrivateAccount(id);
                await repo.follow(id, privateAccount: privateAccount);
                if (!mounted) return;
                await _load();
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not follow user: $e')),
                  );
                }
              } finally {
                if (mounted) setState(() => _busyUsers.remove(id));
              }
            },
      style: OutlinedButton.styleFrom(
        foregroundColor: connected ? Colors.green.shade700 : violet,
        side: BorderSide(
          color: connected ? Colors.green.shade300 : const Color(0xFF363636),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      child: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: violet),
            )
          : Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
    );
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
                        color: Color(0xFF262626),
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
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openUserProfile(
                        context,
                        userId: (user['id'] ?? '').toString(),
                        profile: user,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: igSurface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF363636)),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 27,
                              backgroundColor: const Color(0xFF262626),
                              backgroundImage: avatar.isNotEmpty
                                  ? _twiceAvatarProvider(avatar)
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
                            if (widget.followers &&
                                user['is_current_user'] != true) ...[
                              const SizedBox(width: 8),
                              _followAction(user),
                            ],
                          ],
                        ),
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
  List<SocialPost>? _loadedPosts;
  bool _postsLoading = true;
  String? _postsError;

  String get _uid =>
      Supabase.instance.client.auth.currentUser?.id ??
      (widget.profile['id'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _loadFollowCounts();
    _loadOwnPosts();
  }

  @override
  void didUpdateWidget(covariant ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile['id'] != widget.profile['id']) {
      _countsLoading = true;
      _loadFollowCounts();
      _loadOwnPosts();
    } else if (!identical(oldWidget.posts, widget.posts)) {
      _loadOwnPosts(silent: true);
    }
  }

  Future<void> _loadOwnPosts({bool silent = false}) async {
    final id = _uid;
    if (id.isEmpty) {
      if (mounted) setState(() => _postsLoading = false);
      return;
    }
    if (!silent && mounted) {
      setState(() {
        _postsLoading = true;
        _postsError = null;
      });
    }
    try {
      final rows = await SocialRepository.instance.userPosts(id);
      if (!mounted) return;
      setState(() {
        _loadedPosts = rows.map(SocialPost.new).toList();
        _postsLoading = false;
        _postsError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _postsLoading = false;
        _postsError = _posts.isEmpty ? _searchError(e) : null;
      });
    }
  }

  // Own posts: the complete list when loaded, otherwise the cached feed.
  List<SocialPost> get _posts =>
      _loadedPosts ??
      widget.posts.where((p) => p.data['user_id'] == _uid).toList();

  bool _isPhoto(SocialPost p) => p.media.any((m) {
    final t = (m['media_type'] ?? '').toString().toLowerCase();
    return t == 'image' || t == 'gif';
  });

  bool _isVideo(SocialPost p) => p.media.any(
    (m) => (m['media_type'] ?? '').toString().toLowerCase() == 'video',
  );

  List<SocialPost> get _visiblePosts => selectedTab == 1
      ? _posts.where(_isPhoto).toList()
      : selectedTab == 2
      ? _posts.where(_isVideo).toList()
      : _posts;

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
          backgroundColor: igElevated,
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
                        color: const Color(0xFF262626),
                        width: 3,
                      ),
                    ),
                    child: CircleAvatar(
                      backgroundColor: const Color(0xFF262626),
                      backgroundImage: avatarUrl.isNotEmpty
                          ? _twiceAvatarProvider(avatarUrl)
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
                        border: Border.all(color: const Color(0xFF363636)),
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
                            ? _twiceAvatarProvider(avatarUrl)
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

  void _openFollowList(bool followers) {
    if (_countsLoading) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FollowListPage(
          profileId: (widget.profile['id'] ?? _uid).toString(),
          followers: followers,
        ),
      ),
    );
  }

  Future<void> _openPost(SocialPost post) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PostDetailPage(post: post, authorTappable: false),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _headerCard() {
    final profile = widget.profile;
    final avatar = (profile['avatar_url'] ?? '').toString();
    final username = (profile['username'] ?? '').toString();
    final displayName = (profile['display_name'] ?? '').toString().trim();
    final shownName = displayName.isEmpty ? username : displayName;
    final bio = (profile['bio'] ?? '').toString().trim();
    final isPrivate = profile['is_private'] == true;
    return _IgProfileHeader(
      avatar: avatar,
      name: shownName,
      bio: bio,
      isPrivate: isPrivate,
      posts: _postsLoading && _posts.isEmpty
          ? '…'
          : _compactCount(_posts.length),
      followers: _countsLoading ? '…' : _compactCount(followersCount),
      following: _countsLoading ? '…' : _compactCount(followingCount),
      onFollowers: () => _openFollowList(true),
      onFollowing: () => _openFollowList(false),
      actions: [
        Expanded(
          child: _IgProfileButton(label: 'Edit profile', onPressed: _edit),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _IgProfileButton(
            label: 'Share profile',
            onPressed: _shareProfile,
          ),
        ),
      ],
    );
  }

  Widget _tabBar() {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: canvas,
        border: Border(bottom: BorderSide(color: igBorder, width: 0.5)),
      ),
      child: Row(
        children: [
          _igProfileTab(
            icon: Icons.grid_on_rounded,
            active: selectedTab == 0,
            onTap: () => setState(() => selectedTab = 0),
          ),
          _igProfileTab(
            icon: Icons.photo_outlined,
            active: selectedTab == 1,
            onTap: () => setState(() => selectedTab = 1),
          ),
          _igProfileTab(
            icon: Icons.play_circle_outline_rounded,
            active: selectedTab == 2,
            onTap: () => setState(() => selectedTab = 2),
          ),
        ],
      ),
    );
  }

  List<Widget> _content() {
    final items = _visiblePosts;
    if (_postsLoading && _posts.isEmpty) {
      return [
        SliverPadding(
          padding: EdgeInsets.zero,
          sliver: SliverToBoxAdapter(
            child: SizedBox(
              height: 330,
              child: _Pulse(
                child: GridView.count(
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 3,
                  mainAxisSpacing: 1.5,
                  crossAxisSpacing: 1.5,
                  children: List.generate(
                    9,
                    (_) => DecoratedBox(
                      decoration: const BoxDecoration(color: Color(0xFF262626)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ];
    }
    if (_postsError != null && _posts.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 300,
            child: _SearchEmpty(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load posts',
              subtitle: _postsError!,
              actionLabel: 'Try again',
              onAction: _loadOwnPosts,
            ),
          ),
        ),
      ];
    }
    if (items.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 300,
            child: _SearchEmpty(
              icon: selectedTab == 2
                  ? Icons.play_circle_outline_rounded
                  : selectedTab == 1
                  ? Icons.photo_library_outlined
                  : Icons.grid_on_rounded,
              title: selectedTab == 2
                  ? 'No videos yet'
                  : selectedTab == 1
                  ? 'No photos yet'
                  : 'No posts yet',
              subtitle: 'Share a moment and it will appear here.',
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.zero,
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 1.5,
            crossAxisSpacing: 1.5,
            childAspectRatio: selectedTab == 2 ? 0.72 : 1,
          ),
          delegate: SliverChildBuilderDelegate(
            (_, i) => _MediaGridTile(
              post: items[i],
              onTap: () => _openPost(items[i]),
            ),
            childCount: items.length,
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final username = (widget.profile['username'] ?? '').toString();
    return RefreshIndicator(
      color: violet,
      onRefresh: () async {
        await widget.onRefresh();
        await Future.wait<void>([
          _loadOwnPosts(silent: true),
          _loadFollowCounts(),
        ]);
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    18,
                    MediaQuery.of(context).padding.top + 8,
                    18,
                    12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                username.isEmpty ? 'Your profile' : username,
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
                                  ? const Color(0xFF262626)
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
                              color: igElevated,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFF363636),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x00000000),
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
              ],
            ),
          ),
          SliverToBoxAdapter(child: _headerCard()),
          SliverPersistentHeader(
            pinned: true,
            delegate: _ProfileTabsDelegate(
              extent: 52 + topPad,
              child: Container(
                color: canvas,
                padding: EdgeInsets.only(top: topPad),
                child: _tabBar(),
              ),
            ),
          ),
          ..._content(),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
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
  bool sending = false;
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
    final body = controller.text.trim();
    if (body.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      await SocialRepository.instance.sendMessage(widget.id, body);
      if (!mounted) return;
      controller.clear();
      setState(() => future = SocialRepository.instance.messages(widget.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Message failed: $e')));
      }
    } finally {
      if (mounted) setState(() => sending = false);
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
                        color: own ? igBlue : igElevated,
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
                  onPressed: sending ? null : _send,
                  icon: sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send, color: violet),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ProfileNavAvatar extends StatelessWidget {
  const _ProfileNavAvatar({
    required this.url,
    required this.fallback,
    required this.selected,
  });

  final String url;
  final String fallback;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final imageSource = url.trim();
    final initial = fallback.trim().isNotEmpty
        ? fallback.trim().characters.first.toUpperCase()
        : 'U';
    final hasImage = _isImageSource(imageSource);

    return Container(
      width: 29,
      height: 29,
      padding: EdgeInsets.all(selected ? 2 : 0),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: selected ? Border.all(color: Colors.white, width: 1.5) : null,
      ),
      child: ClipOval(
        child: hasImage
            ? Image(
                image: _twiceAvatarProvider(imageSource),
                fit: BoxFit.cover,
                width: 29,
                height: 29,
                errorBuilder: (context, error, stackTrace) =>
                    _fallback(initial),
              )
            : _fallback(initial),
      ),
    );
  }

  Widget _fallback(String initial) {
    return ColoredBox(
      color: const Color(0xFF262626),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            color: Color(0xFF0095F6),
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

enum _SocialNavKind { home, search, create, activity, plus }

class _SocialNavIcon extends StatelessWidget {
  const _SocialNavIcon({required this.kind, this.selected = false});

  final _SocialNavKind kind;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    const color = Colors.white;
    final stroke = selected
        ? (kind == _SocialNavKind.search ? 3.0 : 2.35)
        : 1.75;

    return SizedBox(
      width: 27,
      height: 27,
      child: CustomPaint(
        painter: _SocialNavPainter(
          kind: kind,
          color: color,
          stroke: stroke,
          selected: selected,
        ),
      ),
    );
  }
}

class _SocialNavPainter extends CustomPainter {
  const _SocialNavPainter({
    required this.kind,
    required this.color,
    required this.stroke,
    required this.selected,
  });

  final _SocialNavKind kind;
  final Color color;
  final double stroke;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = selected ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (kind) {
      case _SocialNavKind.home:
        final path = Path()
          ..moveTo(3, 12)
          ..lineTo(13.5, 3.5)
          ..lineTo(24, 12)
          ..lineTo(22, 12)
          ..lineTo(22, 23)
          ..lineTo(15.8, 23)
          ..lineTo(15.8, 16.5)
          ..lineTo(11.2, 16.5)
          ..lineTo(11.2, 23)
          ..lineTo(5, 23)
          ..lineTo(5, 12)
          ..close();
        if (selected) {
          canvas.drawPath(path, paint);
          canvas.drawRect(
            const Rect.fromLTWH(11.2, 16.5, 4.6, 6.5),
            Paint()..color = igBlack,
          );
        } else {
          canvas.drawPath(path, outline);
        }

      case _SocialNavKind.search:
        canvas.drawCircle(const Offset(11, 11), 7, outline);
        canvas.drawLine(
          const Offset(16.2, 16.2),
          const Offset(23, 23),
          outline,
        );

      case _SocialNavKind.create:
        final back = RRect.fromRectAndRadius(
          const Rect.fromLTWH(3, 2.5, 17, 19),
          const Radius.circular(3.5),
        );
        final front = RRect.fromRectAndRadius(
          const Rect.fromLTWH(7, 5.5, 17, 19),
          const Radius.circular(3.5),
        );
        canvas.drawRRect(back, outline);
        if (selected) {
          canvas.drawRRect(front, paint);
          final cutout = Paint()..color = igBlack;
          final triangle = Path()
            ..moveTo(13, 11)
            ..lineTo(13, 19)
            ..lineTo(19, 15)
            ..close();
          canvas.drawPath(triangle, cutout);
        } else {
          canvas.drawRRect(front, outline);
          final triangle = Path()
            ..moveTo(13, 11)
            ..lineTo(13, 19)
            ..lineTo(19, 15)
            ..close();
          canvas.drawPath(triangle, outline);
        }

      case _SocialNavKind.plus:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(3, 3, 21, 21),
            const Radius.circular(6),
          ),
          outline,
        );
        final plusPaint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          const Offset(13.5, 8.5),
          const Offset(13.5, 18.5),
          plusPaint,
        );
        canvas.drawLine(
          const Offset(8.5, 13.5),
          const Offset(18.5, 13.5),
          plusPaint,
        );

      case _SocialNavKind.activity:
        final heart = Path()
          ..moveTo(13.5, 23)
          ..cubicTo(11.5, 21, 3, 15, 3, 9)
          ..cubicTo(3, 3, 10, 2, 13.5, 7)
          ..cubicTo(17, 2, 24, 3, 24, 9)
          ..cubicTo(24, 15, 15.5, 21, 13.5, 23)
          ..close();
        canvas.drawPath(heart, selected ? paint : outline);
    }
  }

  @override
  bool shouldRepaint(covariant _SocialNavPainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.color != color ||
      oldDelegate.stroke != stroke ||
      oldDelegate.selected != selected;
}