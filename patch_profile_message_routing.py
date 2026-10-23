from pathlib import Path
from datetime import datetime
import shutil
import sys

path = Path("lib/main.dart")
if not path.is_file():
    sys.exit("ERROR: lib/main.dart not found.")

src = path.read_text()
old = """      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationPage(
            id: id,
            title: shownName.isEmpty ? 'Message' : shownName,
          ),
        ),
      );"""

new = """      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => messaging.MessagesPage(
            initialConversationId: id,
          ),
        ),
      );"""

count = src.count(old)
if count != 1:
    sys.exit(
        f"STOP: expected exactly one profile Message route; found {count}. "
        "No changes made."
    )

if "messaging.MessagesPage(" not in src:
    sys.exit("STOP: messaging.MessagesPage alias not found. No changes made.")

backup = path.with_name(
    f"main.dart.backup-profile-message-routing-{datetime.now():%Y%m%d-%H%M%S}"
)
shutil.copy2(path, backup)

path.write_text(src.replace(old, new, 1))
print("SUCCESS: profile Message now opens the new messaging inbox.")
print(f"Backup: {backup}")
