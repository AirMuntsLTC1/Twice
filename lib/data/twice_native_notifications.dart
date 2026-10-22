import 'dart:ffi';
import 'dart:io';

/// Optional ABI-v2 notification scorer.
/// Falls back to the same deterministic scoring rules when native code
/// is unavailable, so notification delivery never depends on C++.
class TwiceNativeNotifications {
  TwiceNativeNotifications._() {
    if (!Platform.isAndroid) return;
    try {
      final lib = DynamicLibrary.open('libtwice_native.so');
      final abi = lib.lookupFunction<Int32 Function(), int Function()>(
        'twice_native_abi_version',
      );
      if (abi() != 2) return;
      _nativePriority = lib
          .lookupFunction<
            Int32 Function(Int32, Int32, Int32),
            int Function(int, int, int)
          >('twice_native_notification_priority_v2');
    } catch (_) {
      _nativePriority = null;
    }
  }

  static final TwiceNativeNotifications instance = TwiceNativeNotifications._();

  int Function(int, int, int)? _nativePriority;

  static int typeCode(String type) {
    switch (type) {
      case 'message':
        return 1;
      case 'like':
        return 2;
      case 'comment':
        return 3;
      case 'reply':
        return 4;
      case 'follow':
        return 5;
      case 'follow_request':
        return 6;
      case 'follow_accept':
        return 7;
      case 'story_reaction':
        return 8;
      case 'story_reply':
        return 9;
      case 'save':
        return 10;
      default:
        return 0;
    }
  }

  int priorityFor(String type, bool isForeground, int ageSeconds) {
    final code = typeCode(type);
    final age = ageSeconds.clamp(0, 2147483647).toInt();
    final native = _nativePriority;
    if (native != null) {
      try {
        return native(code, isForeground ? 1 : 0, age);
      } catch (_) {
        _nativePriority = null;
      }
    }

    var score = switch (code) {
      1 => 100,
      3 || 4 => 70,
      2 => 55,
      5 || 6 || 7 => 45,
      >= 8 && <= 10 => 35,
      _ => 10,
    };
    if (isForeground) score -= 5;
    if (age > 0) score -= (age ~/ 120).clamp(0, 30);
    return score.clamp(0, 100).toInt();
  }

  bool get isNativeAvailable => _nativePriority != null;
}
