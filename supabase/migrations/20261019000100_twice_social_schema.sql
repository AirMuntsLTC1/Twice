begin;

-- User profiles
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (length(username) between 3 and 30),
  display_name text not null default '',
  bio text not null default '',
  avatar_url text,
  is_private boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Follow relationships
create table public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  following_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'accepted'
    check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);

-- Blocks
create table public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

-- Posts
create table public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  caption text not null default '',
  visibility text not null default 'public'
    check (visibility in ('public','followers','private')),
  comments_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Media attached to posts
create table public.post_media (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  media_url text not null,
  media_type text not null check (media_type in ('image','video','gif')),
  position integer not null default 0,
  width integer,
  height integer,
  created_at timestamptz not null default now()
);

-- Likes
create table public.post_likes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- Comments and replies
create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  parent_id uuid references public.comments(id) on delete cascade,
  body text not null check (length(trim(body)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.comment_likes (
  comment_id uuid not null references public.comments(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);

-- Saved posts
create table public.saved_posts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

-- Stories
create table public.stories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  media_url text not null,
  media_type text not null check (media_type in ('image','video')),
  caption text not null default '',
  expires_at timestamptz not null default (now() + interval '24 hours'),
  created_at timestamptz not null default now()
);

create table public.story_views (
  story_id uuid not null references public.stories(id) on delete cascade,
  viewer_id uuid not null references public.profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (story_id, viewer_id)
);

create table public.story_reactions (
  story_id uuid not null references public.stories(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  reaction text not null default '❤️',
  created_at timestamptz not null default now(),
  primary key (story_id, user_id)
);

-- Direct messages
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  is_group boolean not null default false,
  title text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  last_read_at timestamptz,
  primary key (conversation_id, user_id)
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null default '',
  media_url text,
  media_type text check (media_type is null or media_type in ('image','video','audio','file')),
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted_at timestamptz
);

-- Notifications
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  type text not null check (type in ('follow','follow_request','like','comment','reply','message','story_reaction')),
  post_id uuid references public.posts(id) on delete cascade,
  comment_id uuid references public.comments(id) on delete cascade,
  story_id uuid references public.stories(id) on delete cascade,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

-- Query indexes
create index follows_following_idx on public.follows(following_id, status);
create index posts_user_created_idx on public.posts(user_id, created_at desc);
create index posts_created_idx on public.posts(created_at desc);
create index post_media_post_idx on public.post_media(post_id, position);
create index post_likes_user_idx on public.post_likes(user_id);
create index comments_post_created_idx on public.comments(post_id, created_at);
create index comments_parent_idx on public.comments(parent_id);
create index comment_likes_user_idx on public.comment_likes(user_id);
create index stories_user_expiry_idx on public.stories(user_id, expires_at desc);
create index story_views_viewer_idx on public.story_views(viewer_id);
create index messages_conversation_created_idx on public.messages(conversation_id, created_at desc);
create index notifications_recipient_created_idx on public.notifications(recipient_id, created_at desc);

-- Enable RLS everywhere
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','follows','blocks','posts','post_media','post_likes',
    'comments','comment_likes','saved_posts','stories','story_views',
    'story_reactions','conversations','conversation_members','messages',
    'notifications'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Profiles: readable to signed-in users; owners manage their own profile
create policy "profiles_read_authenticated" on public.profiles
for select to authenticated using (true);
create policy "profiles_insert_self" on public.profiles
for insert to authenticated with check (id = (select auth.uid()));
create policy "profiles_update_self" on public.profiles
for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

-- Follow requests and relationships
create policy "follows_read_participants" on public.follows
for select to authenticated
using (follower_id = (select auth.uid()) or following_id = (select auth.uid()));
create policy "follows_create_self" on public.follows
for insert to authenticated
with check (follower_id = (select auth.uid()));
create policy "follows_delete_participant" on public.follows
for delete to authenticated
using (follower_id = (select auth.uid()) or following_id = (select auth.uid()));

-- Blocks are private to the blocker
create policy "blocks_read_own" on public.blocks
for select to authenticated using (blocker_id = (select auth.uid()));
create policy "blocks_insert_own" on public.blocks
for insert to authenticated with check (blocker_id = (select auth.uid()));
create policy "blocks_delete_own" on public.blocks
for delete to authenticated using (blocker_id = (select auth.uid()));

-- Post visibility: public, followers, or owner only
create policy "posts_read_visible" on public.posts
for select to authenticated using (
  user_id = (select auth.uid())
  or (
    visibility = 'public'
    and not exists (
      select 1 from public.blocks b
      where (b.blocker_id = posts.user_id and b.blocked_id = (select auth.uid()))
         or (b.blocker_id = (select auth.uid()) and b.blocked_id = posts.user_id)
    )
    and not exists (
      select 1 from public.profiles p
      where p.id = posts.user_id and p.is_private
    )
  )
  or (
    visibility = 'followers'
    and exists (
      select 1 from public.follows f
      where f.follower_id = (select auth.uid())
        and f.following_id = posts.user_id and f.status = 'accepted'
    )
  )
  or (
    exists (
      select 1 from public.follows f
      where f.follower_id = (select auth.uid())
        and f.following_id = posts.user_id and f.status = 'accepted'
    )
    and exists (
      select 1 from public.profiles p
      where p.id = posts.user_id and p.is_private
    )
  )
);
create policy "posts_insert_self" on public.posts
for insert to authenticated with check (user_id = (select auth.uid()));
create policy "posts_update_self" on public.posts
for update to authenticated using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));
create policy "posts_delete_self" on public.posts
for delete to authenticated using (user_id = (select auth.uid()));

-- Post media follows the parent post's visibility
create policy "post_media_read_visible_post" on public.post_media
for select to authenticated using (
  exists (select 1 from public.posts p where p.id = post_id)
);
create policy "post_media_insert_owner" on public.post_media
for insert to authenticated with check (
  exists (select 1 from public.posts p
    where p.id = post_id and p.user_id = (select auth.uid()))
);
create policy "post_media_delete_owner" on public.post_media
for delete to authenticated using (
  exists (select 1 from public.posts p
    where p.id = post_id and p.user_id = (select auth.uid()))
);

-- Likes: visible to signed-in users, users manage their own
create policy "post_likes_read_authenticated" on public.post_likes
for select to authenticated using (true);
create policy "post_likes_insert_self" on public.post_likes
for insert to authenticated with check (user_id = (select auth.uid()));
create policy "post_likes_delete_self" on public.post_likes
for delete to authenticated using (user_id = (select auth.uid()));

create policy "comments_read_authenticated" on public.comments
for select to authenticated using (true);
create policy "comments_insert_self" on public.comments
for insert to authenticated with check (
  user_id = (select auth.uid()) and exists (
    select 1 from public.posts p where p.id = post_id and p.comments_enabled
  )
);
create policy "comments_update_self" on public.comments
for update to authenticated using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));
create policy "comments_delete_self" on public.comments
for delete to authenticated using (user_id = (select auth.uid()));

create policy "comment_likes_read_authenticated" on public.comment_likes
for select to authenticated using (true);
create policy "comment_likes_insert_self" on public.comment_likes
for insert to authenticated with check (user_id = (select auth.uid()));
create policy "comment_likes_delete_self" on public.comment_likes
for delete to authenticated using (user_id = (select auth.uid()));

create policy "saved_posts_read_own" on public.saved_posts
for select to authenticated using (user_id = (select auth.uid()));
create policy "saved_posts_insert_own" on public.saved_posts
for insert to authenticated with check (user_id = (select auth.uid()));
create policy "saved_posts_delete_own" on public.saved_posts
for delete to authenticated using (user_id = (select auth.uid()));

create policy "stories_read_authenticated" on public.stories
for select to authenticated using (
  user_id = (select auth.uid())
  or (expires_at > now() and (
    not exists (select 1 from public.profiles p where p.id = stories.user_id and p.is_private)
    or exists (select 1 from public.follows f
      where f.follower_id = (select auth.uid())
        and f.following_id = stories.user_id and f.status = 'accepted')
  ))
);
create policy "stories_insert_self" on public.stories
for insert to authenticated with check (user_id = (select auth.uid()));
create policy "stories_update_self" on public.stories
for update to authenticated using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));
create policy "stories_delete_self" on public.stories
for delete to authenticated using (user_id = (select auth.uid()));

create policy "story_views_read_owner_or_viewer" on public.story_views
for select to authenticated using (
  viewer_id = (select auth.uid()) or exists (
    select 1 from public.stories s
    where s.id = story_id and s.user_id = (select auth.uid())
  )
);
create policy "story_views_insert_self" on public.story_views
for insert to authenticated with check (viewer_id = (select auth.uid()));
create policy "story_reactions_read_authenticated" on public.story_reactions
for select to authenticated using (true);
create policy "story_reactions_insert_self" on public.story_reactions
for insert to authenticated with check (user_id = (select auth.uid()));
create policy "story_reactions_delete_self" on public.story_reactions
for delete to authenticated using (user_id = (select auth.uid()));

-- Conversation access is limited to members
create policy "conversations_read_members" on public.conversations
for select to authenticated using (
  exists (select 1 from public.conversation_members cm
    where cm.conversation_id = id and cm.user_id = (select auth.uid()))
);
create policy "conversations_create_self" on public.conversations
for insert to authenticated with check (created_by = (select auth.uid()));
create policy "conversation_members_read_members" on public.conversation_members
for select to authenticated using (
  exists (select 1 from public.conversation_members cm
    where cm.conversation_id = conversation_id and cm.user_id = (select auth.uid()))
);
create policy "conversation_members_add_creator_or_self" on public.conversation_members
for insert to authenticated with check (
  user_id = (select auth.uid()) or exists (
    select 1 from public.conversations c
    where c.id = conversation_id and c.created_by = (select auth.uid())
  )
);
create policy "conversation_members_remove_self" on public.conversation_members
for delete to authenticated using (user_id = (select auth.uid()));

create policy "messages_read_members" on public.messages
for select to authenticated using (
  exists (select 1 from public.conversation_members cm
    where cm.conversation_id = conversation_id and cm.user_id = (select auth.uid()))
);
create policy "messages_insert_members" on public.messages
for insert to authenticated with check (
  sender_id = (select auth.uid()) and exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = conversation_id and cm.user_id = (select auth.uid())
  )
);
create policy "messages_update_sender" on public.messages
for update to authenticated using (sender_id = (select auth.uid()))
with check (sender_id = (select auth.uid()));
create policy "messages_delete_sender" on public.messages
for delete to authenticated using (sender_id = (select auth.uid()));

create policy "notifications_read_own" on public.notifications
for select to authenticated using (recipient_id = (select auth.uid()));
create policy "notifications_update_own" on public.notifications
for update to authenticated using (recipient_id = (select auth.uid()))
with check (recipient_id = (select auth.uid()));

-- Storage buckets: private by default; upload rules are owner-folder based
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 5242880, array['image/jpeg','image/png','image/webp']),
  ('post-media', 'post-media', false, 52428800, array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm']),
  ('stories', 'stories', false, 52428800, array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm']),
  ('chat-media', 'chat-media', false, 26214400, array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','audio/mpeg','application/pdf'])
on conflict (id) do nothing;

create policy "avatars_read_public" on storage.objects
for select to authenticated using (bucket_id = 'avatars');
create policy "avatars_insert_own_folder" on storage.objects
for insert to authenticated with check (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy "avatars_update_own_folder" on storage.objects
for update to authenticated using (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text
) with check (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy "avatars_delete_own_folder" on storage.objects
for delete to authenticated using (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "post_media_read_authenticated" on storage.objects
for select to authenticated using (bucket_id = 'post-media');
create policy "post_media_insert_own_folder" on storage.objects
for insert to authenticated with check (
  bucket_id = 'post-media' and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy "post_media_update_own_folder" on storage.objects
for update to authenticated using (
  bucket_id = 'post-media' and (storage.foldername(name))[1] = (select auth.uid())::text
) with check (
  bucket_id = 'post-media' and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy "post_media_delete_own_folder" on storage.objects
for delete to authenticated using (
  bucket_id = 'post-media' and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "stories_read_authenticated" on storage.objects
for select to authenticated using (bucket_id = 'stories');
create policy "stories_insert_own_folder" on storage.objects
for insert to authenticated with check (
  bucket_id = 'stories' and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy "stories_delete_own_folder" on storage.objects
for delete to authenticated using (
  bucket_id = 'stories' and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "chat_media_read_authenticated" on storage.objects
for select to authenticated using (bucket_id = 'chat-media');
create policy "chat_media_insert_own_folder" on storage.objects
for insert to authenticated with check (
  bucket_id = 'chat-media' and (storage.foldername(name))[1] = (select auth.uid())::text
);
create policy "chat_media_delete_own_folder" on storage.objects
for delete to authenticated using (
  bucket_id = 'chat-media' and (storage.foldername(name))[1] = (select auth.uid())::text
);

commit;
