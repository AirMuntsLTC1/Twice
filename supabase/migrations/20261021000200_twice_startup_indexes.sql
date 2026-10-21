-- Faster feed / story lookups (safe to run more than once).
create index if not exists saved_posts_post_idx on public.saved_posts (post_id);
create index if not exists stories_expires_idx on public.stories (expires_at);
create index if not exists post_media_thumb_idx on public.post_media (post_id) where thumbnail_url is not null;
analyze public.posts;
analyze public.post_media;
analyze public.post_likes;
