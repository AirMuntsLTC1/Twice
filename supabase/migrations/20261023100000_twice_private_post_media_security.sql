BEGIN;

-- Keep the dedicated profile-avatar policy unchanged.
-- Avatar objects use: userId/avatar_filename.ext

DROP POLICY IF EXISTS post_media_read_authenticated ON storage.objects;
DROP POLICY IF EXISTS post_media_read_visible_post ON storage.objects;

CREATE POLICY post_media_read_visible_post
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'post-media'
  AND name !~ '^[^/]+/avatar_[^/]+$'
  AND EXISTS (
    SELECT 1
    FROM public.posts p
    JOIN public.profiles pr ON pr.id = p.user_id
    WHERE p.id::text = (storage.foldername(name))[2]
      AND p.user_id::text = (storage.foldername(name))[1]
      AND (
        p.user_id = (SELECT auth.uid())
        OR (
          NOT EXISTS (
            SELECT 1
            FROM public.blocks b
            WHERE
              (b.blocker_id = p.user_id
               AND b.blocked_id = (SELECT auth.uid()))
              OR
              (b.blocker_id = (SELECT auth.uid())
               AND b.blocked_id = p.user_id)
          )
          AND (
            NOT pr.is_private
            OR EXISTS (
              SELECT 1
              FROM public.follows f
              WHERE f.follower_id = (SELECT auth.uid())
                AND f.following_id = p.user_id
                AND f.status = 'accepted'
            )
          )
          AND (
            p.visibility = 'public'
            OR (
              p.visibility = 'followers'
              AND EXISTS (
                SELECT 1
                FROM public.follows f
                WHERE f.follower_id = (SELECT auth.uid())
                  AND f.following_id = p.user_id
                  AND f.status = 'accepted'
              )
            )
          )
        )
      )
  )
);

COMMIT;
