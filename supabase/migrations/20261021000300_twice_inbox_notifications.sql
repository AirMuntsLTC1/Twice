-- Twice Inbox: creates notifications automatically + turns on realtime.
-- Paste this whole file into Supabase Dashboard > SQL Editor > Run.
-- Safe to run more than once.

-- 1) Columns / allowed types ---------------------------------------------
alter table public.notifications add column if not exists body text;

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (
  type = any (array['follow','follow_request','like','comment','reply',
                    'message','story_reaction','story_reply']::text[])
);

create index if not exists notifications_recipient_idx
  on public.notifications (recipient_id, is_read, created_at desc);

-- 2) Trigger functions ----------------------------------------------------
create or replace function public.twice_notify_like() returns trigger
language plpgsql security definer set search_path = '' as $$
declare owner uuid;
begin
  select user_id into owner from public.posts where id = new.post_id;
  if owner is null or owner = new.user_id then return new; end if;
  delete from public.notifications
   where recipient_id = owner and actor_id = new.user_id
     and type = 'like' and post_id = new.post_id;
  insert into public.notifications (recipient_id, actor_id, type, post_id)
  values (owner, new.user_id, 'like', new.post_id);
  return new;
end $$;

create or replace function public.twice_unnotify_like() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.notifications
   where actor_id = old.user_id and type = 'like' and post_id = old.post_id;
  return old;
end $$;

create or replace function public.twice_notify_comment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare owner uuid; parent_author uuid;
begin
  select user_id into owner from public.posts where id = new.post_id;
  if new.parent_id is not null then
    select user_id into parent_author from public.comments where id = new.parent_id;
    if parent_author is not null and parent_author <> new.user_id then
      insert into public.notifications
        (recipient_id, actor_id, type, post_id, comment_id, body)
      values (parent_author, new.user_id, 'reply', new.post_id, new.id, left(new.body, 200));
    end if;
  end if;
  if owner is not null and owner <> new.user_id
     and owner is distinct from parent_author then
    insert into public.notifications
      (recipient_id, actor_id, type, post_id, comment_id, body)
    values (owner, new.user_id, 'comment', new.post_id, new.id, left(new.body, 200));
  end if;
  return new;
end $$;

create or replace function public.twice_notify_follow() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.notifications
   where recipient_id = new.following_id and actor_id = new.follower_id
     and type in ('follow','follow_request');
  insert into public.notifications (recipient_id, actor_id, type)
  values (new.following_id, new.follower_id,
          case when new.status = 'pending' then 'follow_request' else 'follow' end);
  return new;
end $$;

create or replace function public.twice_notify_follow_accept() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'pending' and new.status = 'accepted' then
    delete from public.notifications
     where recipient_id = new.following_id and actor_id = new.follower_id
       and type in ('follow','follow_request');
    insert into public.notifications (recipient_id, actor_id, type)
    values (new.following_id, new.follower_id, 'follow');
  end if;
  return new;
end $$;

create or replace function public.twice_unnotify_follow() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.notifications
   where recipient_id = old.following_id and actor_id = old.follower_id
     and type in ('follow','follow_request');
  return old;
end $$;

create or replace function public.twice_notify_story_reaction() returns trigger
language plpgsql security definer set search_path = '' as $$
declare owner uuid;
begin
  select user_id into owner from public.stories where id = new.story_id;
  if owner is null or owner = new.user_id then return new; end if;
  delete from public.notifications
   where recipient_id = owner and actor_id = new.user_id
     and type = 'story_reaction' and story_id = new.story_id;
  insert into public.notifications (recipient_id, actor_id, type, story_id)
  values (owner, new.user_id, 'story_reaction', new.story_id);
  return new;
end $$;

create or replace function public.twice_unnotify_story_reaction() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.notifications
   where actor_id = old.user_id and type = 'story_reaction' and story_id = old.story_id;
  return old;
end $$;

create or replace function public.twice_notify_story_reply() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.body like 'Replied to your story:%' then
    insert into public.notifications (recipient_id, actor_id, type, body)
    select m.user_id, new.sender_id, 'story_reply',
           left(btrim(substr(new.body, length('Replied to your story:') + 1)), 300)
      from public.conversation_members m
     where m.conversation_id = new.conversation_id
       and m.user_id <> new.sender_id;
  end if;
  return new;
end $$;

-- Trigger functions must not be callable from the API.
revoke all on function public.twice_notify_like(), public.twice_unnotify_like(),
  public.twice_notify_comment(), public.twice_notify_follow(),
  public.twice_notify_follow_accept(), public.twice_unnotify_follow(),
  public.twice_notify_story_reaction(), public.twice_unnotify_story_reaction(),
  public.twice_notify_story_reply()
  from public, anon, authenticated;

-- 3) Triggers -------------------------------------------------------------
drop trigger if exists twice_like_notify on public.post_likes;
create trigger twice_like_notify after insert on public.post_likes
  for each row execute function public.twice_notify_like();
drop trigger if exists twice_like_unnotify on public.post_likes;
create trigger twice_like_unnotify after delete on public.post_likes
  for each row execute function public.twice_unnotify_like();

drop trigger if exists twice_comment_notify on public.comments;
create trigger twice_comment_notify after insert on public.comments
  for each row execute function public.twice_notify_comment();

drop trigger if exists twice_follow_notify on public.follows;
create trigger twice_follow_notify after insert on public.follows
  for each row execute function public.twice_notify_follow();
drop trigger if exists twice_follow_accept_notify on public.follows;
create trigger twice_follow_accept_notify after update on public.follows
  for each row execute function public.twice_notify_follow_accept();
drop trigger if exists twice_follow_unnotify on public.follows;
create trigger twice_follow_unnotify after delete on public.follows
  for each row execute function public.twice_unnotify_follow();

drop trigger if exists twice_story_reaction_notify on public.story_reactions;
create trigger twice_story_reaction_notify after insert on public.story_reactions
  for each row execute function public.twice_notify_story_reaction();
drop trigger if exists twice_story_reaction_unnotify on public.story_reactions;
create trigger twice_story_reaction_unnotify after delete on public.story_reactions
  for each row execute function public.twice_unnotify_story_reaction();

drop trigger if exists twice_story_reply_notify on public.messages;
create trigger twice_story_reply_notify after insert on public.messages
  for each row execute function public.twice_notify_story_reply();

-- 4) Realtime -------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public' and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- 5) One-time backfill so your inbox is not empty (marked as already read) -
do $$
begin
  if not exists (select 1 from public.notifications) then
    insert into public.notifications
      (recipient_id, actor_id, type, post_id, is_read, created_at)
    select p.user_id, l.user_id, 'like', l.post_id, true, l.created_at
      from public.post_likes l join public.posts p on p.id = l.post_id
     where l.user_id <> p.user_id and l.created_at > now() - interval '30 days';

    insert into public.notifications
      (recipient_id, actor_id, type, post_id, comment_id, body, is_read, created_at)
    select p.user_id, c.user_id, 'comment', c.post_id, c.id, left(c.body, 200), true, c.created_at
      from public.comments c join public.posts p on p.id = c.post_id
     where c.parent_id is null and c.user_id <> p.user_id
       and c.created_at > now() - interval '30 days';

    insert into public.notifications
      (recipient_id, actor_id, type, is_read, created_at)
    select f.following_id, f.follower_id,
           case when f.status = 'pending' then 'follow_request' else 'follow' end,
           true, f.created_at
      from public.follows f
     where f.created_at > now() - interval '30 days';

    insert into public.notifications
      (recipient_id, actor_id, type, story_id, is_read, created_at)
    select s.user_id, r.user_id, 'story_reaction', r.story_id, true, r.created_at
      from public.story_reactions r join public.stories s on s.id = r.story_id
     where r.user_id <> s.user_id and r.created_at > now() - interval '30 days';
  end if;
end $$;
