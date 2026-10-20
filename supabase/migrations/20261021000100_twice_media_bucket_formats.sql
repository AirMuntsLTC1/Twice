-- Allow common phone-captured image/video formats used by the custom picker.
-- Keep the buckets private; this only widens accepted upload MIME types.
begin;

update storage.buckets
set
  allowed_mime_types = array(
    select distinct allowed.mime
    from unnest(coalesce(allowed_mime_types, array[]::text[]) || array[
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
      'image/heic',
      'image/heif',
      'image/avif',
      'video/mp4',
      'video/webm',
      'video/quicktime',
      'video/x-m4v',
      'video/3gpp',
      'video/x-matroska'
    ]::text[]) as allowed(mime)
    order by allowed.mime
  ),
  file_size_limit = greatest(coalesce(file_size_limit, 0), 52428800)
where id in ('post-media', 'stories');

commit;
