from pathlib import Path
from datetime import datetime
import shutil
import sys

service = Path("lib/data/notification_service.dart")
push = Path("lib/data/push_notification_service.dart")

if not service.is_file() or not push.is_file():
    sys.exit("FAIL: required source file missing.")

s = service.read_text()
p = push.read_text()

anchor = """  /// Enqueue a notification for in-app banner + optional system tray.
  Future<void> present(TwiceNotificationEvent event) async {"""

replacement = """  /// Display a system notification from an FCM background isolate.
  /// Does not enqueue an in-app banner or trigger foreground haptics.
  Future<void> presentBackground(TwiceNotificationEvent event) async {
    if (!_ready) await init();
    if (!_ready) return;
    await _showSystem(event);
  }

  /// Enqueue a notification for in-app banner + optional system tray.
  Future<void> present(TwiceNotificationEvent event) async {"""

old_call = "    await NotificationService.instance.present(event);"

if s.count(anchor) != 1:
    sys.exit("FAIL: present() insertion point did not match exactly once.")
if p.count(old_call) != 1:
    sys.exit("FAIL: background present() call did not match exactly once.")

stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
backups = [
    (service, Path(str(service) + f".backup-background-display-{stamp}")),
    (push, Path(str(push) + f".backup-background-display-{stamp}")),
]

for source, backup in backups:
    shutil.copy2(source, backup)

try:
    service.write_text(s.replace(anchor, replacement, 1))
    push.write_text(p.replace(
        old_call,
        "    await NotificationService.instance.presentBackground(event);",
        1,
    ))
except Exception:
    for source, backup in backups:
        shutil.copy2(backup, source)
    sys.exit("FAIL: edit failed; originals restored.")

print("SUCCESS: background handler now displays directly via _showSystem().")
for _, backup in backups:
    print(f"Backup: {backup}")
