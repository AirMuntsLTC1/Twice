from pathlib import Path
from datetime import datetime
import shutil
import zipfile

root = Path.cwd()
service = root / "lib/data/notification_service.dart"
native_cpp = root / "android/app/src/main/cpp/twice_native.cpp"
adapter = root / "lib/data/twice_native_notifications.dart"

if not service.is_file() or not native_cpp.is_file():
    raise RuntimeError("Required notification or C++ source file is missing.")

original = service.read_text()
cpp = native_cpp.read_text()

required_cpp = [
    "twice_native_abi_version",
    "twice_native_notification_priority_v2",
    "twice_native_notification_type_code",
]
for symbol in required_cpp:
    if symbol not in cpp:
        raise RuntimeError(f"Required C++ export not found: {symbol}")

import_line = "import 'twice_native_notifications.dart';"
queue_line = "    _queue.add(event);"

if original.count(queue_line) != 1:
    raise RuntimeError("Expected exactly one notification queue insertion.")
if import_line in original:
    raise RuntimeError("Native adapter import already exists; inspect before rerunning.")

stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
backup = root / "backups" / f"before-native-notification-{stamp}"
backup.mkdir(parents=True, exist_ok=False)
shutil.copy2(service, backup / "notification_service.dart")
if adapter.exists():
    shutil.copy2(adapter, backup / "twice_native_notifications.dart")

adapter_source = r"""import 'dart:ffi';
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
      _nativePriority =
          lib.lookupFunction<
            Int32 Function(Int32, Int32, Int32),
            int Function(int, int, int)
          >('twice_native_notification_priority_v2');
    } catch (_) {
      _nativePriority = null;
    }
  }

  static final TwiceNativeNotifications instance =
      TwiceNativeNotifications._();

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
"""

adapter.write_text(adapter_source)

updated = original.replace(
    "import 'package:supabase_flutter/supabase_flutter.dart';",
    "import 'package:supabase_flutter/supabase_flutter.dart';\n" + import_line,
    1,
)
if updated == original:
    adapter.unlink(missing_ok=True)
    raise RuntimeError("Could not locate the Supabase import for a safe insertion.")

replacement = """    _queue.add(event);
    final foreground = lifecycle == AppLifecycleState.resumed;
    int ageSeconds(TwiceNotificationEvent item) {
      final createdAt = item.createdAt;
      if (createdAt == null) return 0;
      return now.difference(createdAt).inSeconds
          .clamp(0, 2147483647)
          .toInt();
    }

    _queue.sort((a, b) {
      final aPriority = TwiceNativeNotifications.instance.priorityFor(
        a.type, foreground, ageSeconds(a),
      );
      final bPriority = TwiceNativeNotifications.instance.priorityFor(
        b.type, foreground, ageSeconds(b),
      );
      return bPriority.compareTo(aPriority);
    });
"""
updated = updated.replace(queue_line, replacement.rstrip(), 1)
service.write_text(updated)

readme = """Twice native notification scoring update

Files:
- lib/data/notification_service.dart
- lib/data/twice_native_notifications.dart
- android/app/src/main/cpp/twice_native.cpp

The adapter uses C++ ABI v2 notification priority when available and
falls back to Dart scoring when the native library is unavailable.
It only orders queued in-app banners; Firebase delivery, Android system
notification display, payloads, and navigation routing remain in Dart.

Apply these files to the matching paths in the Twice project.
Do not include backups, credentials, or environment files.
"""
readme_path = root / "TWICE_NATIVE_NOTIFICATION_README.txt"
readme_path.write_text(readme)

zip_path = root / f"twice_native_notification_update_{stamp}.zip"
if zip_path.exists():
    raise RuntimeError(f"Refusing to overwrite existing ZIP: {zip_path.name}")

files = [
    service,
    adapter,
    native_cpp,
    readme_path,
]
with zipfile.ZipFile(zip_path, "x", zipfile.ZIP_DEFLATED) as archive:
    for file in files:
        archive.write(file, file.relative_to(root).as_posix())

print("Patch applied and ZIP created:")
print(zip_path)
print("Backup directory:")
print(backup)
print("ZIP contents:")
with zipfile.ZipFile(zip_path) as archive:
    for name in archive.namelist():
        print(" -", name)
