DROP POLICY IF EXISTS chat_media_read_conversation_members ON storage.objects;

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
)
