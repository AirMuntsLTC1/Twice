BEGIN;

DROP POLICY IF EXISTS profile_avatar_read_public ON storage.objects;
DROP POLICY IF EXISTS profile_avatar_read_authenticated ON storage.objects;

CREATE POLICY profile_avatar_read_authenticated
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'post-media'
  AND name ~ '^[^/]+/avatar_[^/]+$'
);

COMMIT;
