BEGIN;

DROP POLICY IF EXISTS chat_media_read_authenticated ON storage.objects;
DROP POLICY IF EXISTS post_media_read_authenticated ON storage.objects;
DROP POLICY IF EXISTS stories_read_authenticated ON storage.objects;

CREATE POLICY post_media_read_visible_post
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'post-media'
  AND EXISTS (
    SELECT 1
    FROM public.posts p
    WHERE p.id::text = (storage.foldername(name))[2]
      AND p.user_id::text = (storage.foldername(name))[1]
  )
);

CREATE POLICY stories_read_visible_story
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'stories'
  AND EXISTS (
    SELECT 1
    FROM public.stories s
    WHERE s.id::text = (storage.foldername(name))[2]
      AND s.user_id::text = (storage.foldername(name))[1]
  )
);

CREATE POLICY chat_media_read_conversation_members
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'chat-media'
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
  AND EXISTS (
    SELECT 1
    FROM public.conversation_members cm
    WHERE cm.conversation_id::text = (storage.foldername(name))[2]
      AND cm.user_id = (SELECT auth.uid())
  )
);

COMMIT;
