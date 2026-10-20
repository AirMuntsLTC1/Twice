-- Add an optional video poster URL without changing existing media rows.
ALTER TABLE public.post_media
ADD COLUMN IF NOT EXISTS thumbnail_url text;
