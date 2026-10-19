BEGIN;

-- Chat objects use: uploader_user_id/conversation_id/filename.
-- Any authenticated member of that conversation can read attachments,
-- while writes and deletes remain restricted to the uploader's own folder.
DROP POLICY IF EXISTS chat_media_read_conversation_members ON storage.objects;
DROP POLICY IF EXISTS chat_media_read_authenticated ON storage.objects;

CREATE POLICY chat_media_read_conversation_members
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'chat-media'
  AND (storage.foldername(name))[2] IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM public.conversation_members cm
    WHERE cm.conversation_id::text = (storage.foldername(name))[2]
      AND cm.user_id = (SELECT auth.uid())
  )
);

COMMIT;
