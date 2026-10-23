# VALIDATION.md

Performed:
- All exact-match anchors found exactly once before any write.
- Backups written to backups/perf_20261023_111611/.
- ZIP integrity: ZipFile.testzip() returned None.
- SHA-256 written next to the archive.

NOT performed:
- flutter analyze / flutter test / flutter build apk
- Runtime profiling

Run the existing GitHub Actions workflow to validate this patch.
