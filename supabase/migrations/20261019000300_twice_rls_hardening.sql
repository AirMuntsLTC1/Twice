begin;

-- Posts: private accounts require accepted followers.
-- Posts marked private remain visible only to their owner.
drop policy if exists "posts_read_visible" on public.posts;
create policy "posts_read_visible"
on public.posts for select to authenticated
using (
  user_id = (select auth.uid())
  or (
    not exists (
      select 1 from public.blocks b
      where (b.blocker_id = posts.user_id and b.blocked_id = (select auth.uid()))
         or (b.blocker_id = (select auth.uid()) and b.blocked_id = posts.user_id)
    )
    and exists (
      select 1 from public.profiles p
      where p.id = posts.user_id
        and (
          not p.is_private
          or exists (
            select 1 from public.follows f
            where f.follower_id = (select auth.uid())
              and f.following_id = posts.user_id
              and f.status = 'accepted'
          )
        )
    )
    and (
      visibility = 'public'
      or (
        visibility = 'followers'
        and exists (
          select 1 from public.follows f
          where f.follower_id = (select auth.uid())
            and f.following_id = posts.user_id
            and f.status = 'accepted'
        )
      )
    )
  )
);

-- Follow requests: private accounts require pending requests.
drop policy if exists "follows_create_self" on public.follows;
create policy "follows_create_self"
on public.follows for insert to authenticated
with check (
  follower_id = (select auth.uid())
  and follower_id <> following_id
  and (
    (status = 'pending' and exists (
      select 1 from public.profiles p
      where p.id = following_id and p.is_private
    ))
    or
    (status = 'accepted' and exists (
      select 1 from public.profiles p
      where p.id = following_id and not p.is_private
    ))
  )
);

-- Comments are readable only when the associated post is readable.
drop policy if exists "comments_read_authenticated" on public.comments;
create policy "comments_read_authenticated"
on public.comments for select to authenticated
using (
  exists (select 1 from public.posts p where p.id = post_id)
);

-- Comment likes must belong to a comment on a readable post.
drop policy if exists "comment_likes_read_authenticated" on public.comment_likes;
create policy "comment_likes_read_authenticated"
on public.comment_likes for select to authenticated
using (
  exists (
    select 1 from public.comments c
    join public.posts p on p.id = c.post_id
    where c.id = comment_id
  )
);

drop policy if exists "comment_likes_insert_self" on public.comment_likes;
create policy "comment_likes_insert_self"
on public.comment_likes for insert to authenticated
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.comments c
    join public.posts p on p.id = c.post_id
    where c.id = comment_id
  )
);

-- Post likes: only interact with posts the user can read.
drop policy if exists "post_likes_read_authenticated" on public.post_likes;
create policy "post_likes_read_authenticated"
on public.post_likes for select to authenticated
using (
  exists (select 1 from public.posts p where p.id = post_id)
);

drop policy if exists "post_likes_insert_self" on public.post_likes;
create policy "post_likes_insert_self"
on public.post_likes for insert to authenticated
with check (
  user_id = (select auth.uid())
  and exists (select 1 from public.posts p where p.id = post_id)
);

-- Story reactions only expose reactions on readable stories.
drop policy if exists "story_reactions_read_authenticated" on public.story_reactions;
create policy "story_reactions_read_authenticated"
on public.story_reactions for select to authenticated
using (
  exists (select 1 from public.stories s where s.id = story_id)
);

drop policy if exists "story_reactions_insert_self" on public.story_reactions;
create policy "story_reactions_insert_self"
on public.story_reactions for insert to authenticated
with check (
  user_id = (select auth.uid())
  and exists (select 1 from public.stories s where s.id = story_id)
);

-- Prevent arbitrary users from joining an existing conversation.
-- A user can add themselves only when they created the conversation.
drop policy if exists "conversation_members_add_creator_or_self"
on public.conversation_members;
create policy "conversation_members_add_creator_or_self"
on public.conversation_members for insert to authenticated
with check (
  (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.conversations c
      where c.id = conversation_id
        and c.created_by = (select auth.uid())
    )
  )
  or exists (
    select 1 from public.conversations c
    where c.id = conversation_id
      and c.created_by = (select auth.uid())
  )
);

commit;
