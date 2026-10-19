TWICE STARTUP FIX
=================

Main fix:
- Supabase initialization errors/timeouts no longer prevent runApp() from starting.
- If Supabase is missing or initialization fails, Twice displays its setup/auth screen instead of staying on the Android splash screen.
- Preserves the Flutter UI and C++ native source files from the supplied backup.

Install in Termux (after downloading this ZIP into /sdcard/Download):
  termux-setup-storage
  cd ~
  # Back up an existing project first:
  [ ! -d ~/Twice ] || cp -a ~/Twice ~/Twice_backup_$(date +%Y%m%d_%H%M%S)
  mkdir -p ~/Twice
  unzip -o /sdcard/Download/Twice_STARTUP_FIXED.zip -d ~/Twice
  cd ~/Twice

Important:
- Build with the included GitHub Actions workflow; local Flutter is not required.
- Configure repository variable SUPABASE_URL and secret SUPABASE_PUBLISHABLE_KEY.
- This ZIP was source-inspected but not built/tested in this environment.
