from pathlib import Path
from datetime import datetime
import shutil
import sys

path = Path("lib/ads/native_ad_card.dart")
if not path.is_file():
    sys.exit("ERROR: native_ad_card.dart not found.")

source = path.read_text()
start = source.find("  bool _isNear() {")
end = source.find("\n  void _checkNear()", start)

if start < 0 or end < 0:
    sys.exit("ERROR: Could not locate the complete _isNear() method.")

method = source[start:end]

expected = [
    "if (ro is! RenderBox || !ro.attached || !ro.hasSize || pos == null) {\n        return true;",
    "if (!pos.hasPixels || !pos.hasViewportDimension) return true;",
    "if (viewport == null) return true;",
    "} catch (_) {\n      return true;",
]

for pattern in expected:
    if method.count(pattern) != 1:
        sys.exit(
            "ERROR: Expected method pattern was missing or ambiguous. "
            "No files changed."
        )

updated_method = method
for pattern in expected:
    updated_method = updated_method.replace(
        pattern, pattern.replace("return true;", "return false;"), 1
    )

updated = source[:start] + updated_method + source[end:]
if updated == source:
    sys.exit("ERROR: No changes produced.")

backup = path.with_name(
    path.name + ".backup-attach-guard-" +
    datetime.now().strftime("%Y%m%d-%H%M%S")
)
shutil.copy2(path, backup)
path.write_text(updated)

print("SUCCESS: uncertain viewport geometry now keeps inline native ads detached.")
print(f"Backup: {backup}")
