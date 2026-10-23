-- Comment media: GIF / sticker / animated emoji (Giphy URLs) and photos.
alter table public.comments add column if not exists media_url text;
alter table public.comments add column if not exists media_type text;

alter table public.comments drop constraint if exists comments_media_type_check;
alter table public.comments add constraint comments_media_type_check
  check (media_type is null or media_type in ('photo','gif','sticker','emoji'));

-- Allow media-only comments (empty text with an attachment).
alter table public.comments drop constraint if exists comments_body_check;
alter table public.comments add constraint comments_body_check
  check (length(trim(body)) > 0 or media_url is not null);

-- Public bucket for comment photos (images only, no video).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comment-media', 'comment-media', true, 5242880,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "comment_media_insert_own" on storage.objects;
create policy "comment_media_insert_own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'comment-media'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "comment_media_read" on storage.objects;
create policy "comment_media_read" on storage.objects
  for select to public
  using (bucket_id = 'comment-media');

drop policy if exists "comment_media_delete_own" on storage.objects;
create policy "comment_media_delete_own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'comment-media'
         and (storage.foldername(name))[1] = auth.uid()::text);
