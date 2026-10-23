from pathlib import Path
from datetime import datetime
import shutil
import sys

path = Path("lib/messages_page.dart")
if not path.is_file():
    sys.exit("STOP: lib/messages_page.dart not found.")

src = path.read_text()

old = """  Future<void> _openInitialConversationIfRequested() async {
    if (_initialConversationHandled) return;
    final target = (widget.initialConversationId ?? '').trim();
    if (target.isEmpty) return;
    _initialConversationHandled = true;
    // Inbox refresh may not include a new conversation immediately; retry once
    // after a short bounded delay, without creating a navigation loop.
    Map<String, dynamic>? row;
    for (final candidate in _rows) {
      if ((candidate['conversation_id'] ?? '').toString() == target) {
        row = candidate;
        break;
      }
    }
    if (row == null) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      await _refresh();
      for (final candidate in _rows) {
        if ((candidate['conversation_id'] ?? '').toString() == target) {
          row = candidate;
          break;
        }
      }
    }
    if (!mounted || row == null) return;
    await _openConversationRow(row);
  }"""

new = """  Future<void> _openInitialConversationIfRequested() async {
    if (_initialConversationHandled) return;
    final target = (widget.initialConversationId ?? '').trim();
    if (target.isEmpty) return;
    _initialConversationHandled = true;

    // Allow any refresh already in progress to finish before checking rows.
    // Retry briefly because a newly created conversation may not be visible
    // in the inbox query immediately.
    Map<String, dynamic>? row;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!mounted) return;

      for (final candidate in _rows) {
        if ((candidate['conversation_id'] ?? '').toString() == target) {
          row = candidate;
          break;
        }
      }
      if (row != null) break;

      if (_refreshing) {
        for (var wait = 0; wait < 30 && _refreshing; wait++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (!mounted) return;
        }
      }

      if (!_refreshing) {
        await _refresh();
      }

      if (row == null && attempt < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }

    if (!mounted || row == null) return;
    await _openConversationRow(row);
  }"""

count = src.count(old)
if count != 1:
    sys.exit(
        f"STOP: expected exactly one original handler; found {count}. "
        "No changes made."
    )

backup = path.with_name(
    f"messages_page.dart.backup-initial-conversation-wait-{datetime.now():%Y%m%d-%H%M%S}"
)
shutil.copy2(path, backup)
path.write_text(src.replace(old, new, 1))

print("SUCCESS: initial conversation lookup now waits for active refreshes and retries.")
print(f"Backup: {backup}")
