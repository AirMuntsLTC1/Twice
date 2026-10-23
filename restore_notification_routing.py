from pathlib import Path
from datetime import datetime
import subprocess
import shutil
import sys

main_path = Path("lib/main.dart")
messages_path = Path("lib/messages_page.dart")

def read_head(path):
    result = subprocess.run(
        ["git", "show", "HEAD:" + path],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError("Could not read committed source: " + path)
    return result.stdout

main = main_path.read_text()
messages = messages_path.read_text()
head_main = read_head("lib/main.dart")
head_messages = read_head("lib/messages_page.dart")

handler_start_text = (
    "  Future<void> _handleNotificationTap(TwiceNotificationEvent event) async {"
)
head_start = head_main.find(handler_start_text)
head_end = head_main.find("\n\n  void _message(", head_start)

if head_start < 0 or head_end < 0:
    sys.exit("STOP: could not locate committed notification handler.")

current_start = main.find(
    "  void _handleNotificationTap(TwiceNotificationEvent event) {"
)
current_end = main.find("\n\n  void _message(", current_start)

if current_start < 0 or current_end < 0:
    sys.exit("STOP: current handler boundaries did not match.")
if "initialConversationId" in main:
    sys.exit("STOP: unexpected existing conversation target in main.dart.")

handler = head_main[head_start:head_end]

old_constructor = "  const MessagesPage({super.key});"
new_constructor = (
    "  const MessagesPage({super.key, this.initialConversationId});\n\n"
    "  /// Optional deep-link target from a tapped push/system notification.\n"
    "  final String? initialConversationId;"
)

if messages.count(old_constructor) != 1:
    sys.exit("STOP: MessagesPage constructor did not match exactly.")
if "initialConversationId" in messages:
    sys.exit("STOP: conversation target already exists in messages_page.dart.")

methods_start = head_messages.find(
    "  bool _initialConversationHandled = false;"
)
methods_end = head_messages.find("\n  void _listen()", methods_start)

if methods_start < 0 or methods_end < 0:
    sys.exit("STOP: could not locate committed conversation routing methods.")

methods = head_messages[methods_start:methods_end]
if "_openInitialConversationIfRequested" not in methods:
    sys.exit("STOP: initial conversation method is missing.")
if "_openConversationRow" not in methods:
    sys.exit("STOP: conversation-opening method is missing.")

anchor = "    await _refresh();\n  }\n\n  void _listen() {"
if messages.count(anchor) != 1:
    sys.exit("STOP: bootstrap insertion point did not match exactly.")
if "_initialConversationHandled" in messages:
    sys.exit("STOP: conversation routing appears partially restored.")

new_main = main[:current_start] + handler + main[current_end:]
new_messages = messages.replace(old_constructor, new_constructor, 1)
new_messages = new_messages.replace(
    anchor,
    "    await _refresh();\n"
    "    await _openInitialConversationIfRequested();\n"
    "  }\n\n"
    + methods
    + "\n\n  void _listen() {",
    1,
)

if "initialConversationId: event.conversationId" not in new_main:
    sys.exit("STOP: restored handler does not pass the conversation ID.")
if "await _openInitialConversationIfRequested();" not in new_messages:
    sys.exit("STOP: bootstrap call was not inserted.")

backup = Path("backups") / (
    "before-notification-routing-" + datetime.now().strftime("%Y%m%d-%H%M%S")
)
backup.mkdir(parents=True, exist_ok=False)
shutil.copy2(main_path, backup / "main.dart")
shutil.copy2(messages_path, backup / "messages_page.dart")

main_path.write_text(new_main)
messages_path.write_text(new_messages)

print("SUCCESS: restored notification routing.")
print("Backup:", backup)
