import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _igBlack = Color(0xFF000000);
const _igSurface = Color(0xFF121212);
const _igElevated = Color(0xFF262626);
const _igBlue = Color(0xFF0095F6);

class TwicePremiumScreen extends StatefulWidget {
  const TwicePremiumScreen({super.key});

  @override
  State<TwicePremiumScreen> createState() => _TwicePremiumScreenState();
}

class _TwicePremiumScreenState extends State<TwicePremiumScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowController;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  Future<void> _payWithGCash() async {
    setState(() => _processing = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _processing = false);
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Welcome to Twice Premium!'),
        backgroundColor: _igBlue,
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _igBlack,
      appBar: AppBar(
        backgroundColor: _igBlack,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            AnimatedBuilder(
              animation: _glowController,
              builder: (context, child) {
                return Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0095F6)
                            .withValues(alpha: 0.3 + (_glowController.value * 0.4)),
                        blurRadius: 30 + (_glowController.value * 20),
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: child,
                );
              },
              child: Container(
                width: 100,
                height: 100,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFFFF3040),
                      Color(0xFF962FBF),
                      Color(0xFF4F5BD5),
                    ],
                  ),
                ),
                child: const Center(
                  child: Icon(Icons.star_rounded, color: Colors.white, size: 50),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Twice Premium',
              style: TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Stand out with exclusive features.',
              style: TextStyle(color: Color(0xFFA8A8A8), fontSize: 16),
            ),
            const SizedBox(height: 32),
            _feature(Icons.emoji_emotions_rounded, 'Exclusive Animated Emojis'),
            _feature(Icons.verified_rounded, 'Animated Premium Badge'),
            _feature(Icons.color_lens_rounded, 'Custom App Themes'),
            _feature(Icons.bolt_rounded, 'Faster Content Delivery'),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _igSurface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFF363636)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Choose your plan',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: _igBlue.withValues(alpha: .15),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: _igBlue, width: 2),
                          ),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('1 Month',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700)),
                              SizedBox(height: 4),
                              Text('₱59',
                                  style: TextStyle(
                                      color: _igBlue,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: _igElevated,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('1 Year',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700)),
                              SizedBox(height: 4),
                              Text('₱999',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton(
                      onPressed: _processing ? null : _payWithGCash,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF007DFE),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _processing
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.account_balance_wallet_rounded),
                                SizedBox(width: 8),
                                Text(
                                  'Pay with GCash',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      'Auto-renews. Cancel anytime.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .4),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Restore Purchase',
              style: TextStyle(
                color: _igBlue,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _feature(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: _igElevated,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: _igBlue, size: 20),
          ),
          const SizedBox(width: 16),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
