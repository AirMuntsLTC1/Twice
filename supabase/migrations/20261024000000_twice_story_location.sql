ALTER TABLE public.stories
  ADD COLUMN IF NOT EXISTS location_text text;
