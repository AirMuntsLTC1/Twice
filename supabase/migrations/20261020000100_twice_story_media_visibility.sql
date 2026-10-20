DROP POLICY IF EXISTS stories_read_visible_story ON storage.objects;

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
      AND s.expires_at > now()
      AND (
        s.user_id = (SELECT auth.uid())
        OR NOT EXISTS (
          SELECT 1
          FROM public.profiles p
          WHERE p.id = s.user_id
            AND p.is_private
        )
        OR EXISTS (
          SELECT 1
          FROM public.follows f
          WHERE f.follower_id = (SELECT auth.uid())
            AND f.following_id = s.user_id
            AND f.status = 'accepted'
        )
      )
  )
)
