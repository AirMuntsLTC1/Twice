# VALIDATION.md

## Performed
- Preflight: every exact-match anchor was confirmed exactly once before any
  file was written. If any had failed, the script would have exited without
  modifying any file.
- File backups: `media_20261023_112609/` contains copies of the three patched files
  as they were before this run.
- ZIP integrity: `ZipFile.testzip()` returned `None` (no corrupt entries).
- Secret exclusion: `.git/`, `build/`, `.dart_tool/`, `backups/`,
  `supabase_remote_snapshot/`, `.temp`, and any file matching
  `*.pem`, `*.key`, `*.jks`, `google-services.json`, `.env*` were excluded
  from the ZIP.
- SHA-256: written to `<zipname>.sha256`.

## Not performed (environment limitation)
- `flutter analyze`
- `flutter test`
- `flutter build apk`
- Gradle / C++ compile
- Runtime profiling or frame-time measurement

## Required next step
Push the patch to `origin/main` and inspect both GitHub Actions jobs.
If either fails, send the full failing step output. Do not claim the APK is
validated until both jobs are green.
