-- Optional: last_seen_at for profile-level "last active" fallback.
-- Presence in the app is handled by Supabase Realtime Presence (no table required).
-- Apply only if you want a durable last-seen column for future features.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;

COMMENT ON COLUMN public.profiles.last_seen_at IS
  'Optional heartbeat timestamp; UI primary online signal is Realtime Presence.';
