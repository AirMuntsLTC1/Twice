-- Twice Instagram-style messaging support
-- Run in Supabase SQL Editor (safe to re-run).

-- 1) Helper: count conversations with unread messages for a user
create or replace function public.twice_unread_conversation_count(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.conversation_members cm
  where cm.user_id = p_user_id
    and exists (
      select 1
      from public.messages m
      where m.conversation_id = cm.conversation_id
        and m.deleted_at is null
        and m.sender_id <> p_user_id
        and (cm.last_read_at is null or m.created_at > cm.last_read_at)
    );
$$;

grant execute on function public.twice_unread_conversation_count(uuid) to authenticated;

-- 2) Notify the other member(s) when a new message is inserted
create or replace function public.twice_notify_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  member record;
  preview text;
begin
  preview := left(coalesce(nullif(trim(new.body), ''), 
    case when new.media_type = 'image' then 'Sent a photo'
         when new.media_type = 'video' then 'Sent a video'
         else 'New message' end), 200);

  for member in
    select user_id
    from public.conversation_members
    where conversation_id = new.conversation_id
      and user_id <> new.sender_id
  loop
    insert into public.notifications (recipient_id, actor_id, type, body, is_read)
    values (member.user_id, new.sender_id, 'message', preview, false);
  end loop;
  return new;
end;
$$;

drop trigger if exists twice_message_notify on public.messages;
create trigger twice_message_notify
  after insert on public.messages
  for each row execute function public.twice_notify_message();

-- 3) Ensure 'message' is allowed in notifications.type
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (
  type = any (array[
    'follow','follow_request','like','comment','reply',
    'message','story_reaction','story_reply'
  ]::text[])
);

-- 4) Index for inbox performance
create index if not exists messages_conversation_created_idx
  on public.messages (conversation_id, created_at desc)
  where deleted_at is null;

create index if not exists conversation_members_user_idx
  on public.conversation_members (user_id, joined_at desc);

-- 5) Realtime for messages (so open threads update live)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- 6) Allow authenticated users to read messages of conversations they belong to
-- (policies should already exist; this is a safety net)
do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'messages'
       and policyname = 'messages_read_members'
  ) then
    create policy messages_read_members on public.messages
      for select to authenticated
      using (public.is_conversation_member(conversation_id));
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'messages'
       and policyname = 'messages_insert_members'
  ) then
    create policy messages_insert_members on public.messages
      for insert to authenticated
      with check (
        sender_id = auth.uid()
        and public.is_conversation_member(conversation_id)
      );
  end if;
end $$;
