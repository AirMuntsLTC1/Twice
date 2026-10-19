begin;

-- Avoid recursive conversation-membership RLS checks.
create or replace function public.is_conversation_member(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = (select auth.uid())
  );
$$;

revoke all on function public.is_conversation_member(uuid) from public;
grant execute on function public.is_conversation_member(uuid) to authenticated;

drop policy if exists "conversations_read_members" on public.conversations;
create policy "conversations_read_members"
on public.conversations for select to authenticated
using (public.is_conversation_member(id));

drop policy if exists "conversation_members_read_members" on public.conversation_members;
create policy "conversation_members_read_members"
on public.conversation_members for select to authenticated
using (public.is_conversation_member(conversation_id));

drop policy if exists "messages_read_members" on public.messages;
create policy "messages_read_members"
on public.messages for select to authenticated
using (public.is_conversation_member(conversation_id));

drop policy if exists "messages_insert_members" on public.messages;
create policy "messages_insert_members"
on public.messages for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and public.is_conversation_member(conversation_id)
);

-- Automatically maintain updated_at.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists posts_set_updated_at on public.posts;
create trigger posts_set_updated_at
before update on public.posts
for each row execute function public.set_updated_at();

drop trigger if exists comments_set_updated_at on public.comments;
create trigger comments_set_updated_at
before update on public.comments
for each row execute function public.set_updated_at();

-- Generate a profile automatically when an auth user is created.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_username text;
  candidate text;
  suffix integer := 0;
begin
  base_username := lower(
    regexp_replace(
      coalesce(
        new.raw_user_meta_data ->> 'username',
        split_part(coalesce(new.email, 'user'), '@', 1)
      ),
      '[^a-zA-Z0-9_]', '', 'g'
    )
  );

  if length(base_username) < 3 then
    base_username := 'user' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;

  base_username := substr(base_username, 1, 24);
  candidate := base_username;

  while exists (
    select 1 from public.profiles p where p.username = candidate
  ) loop
    suffix := suffix + 1;
    candidate := substr(base_username, 1, 24) || suffix::text;
  end loop;

  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    candidate,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'display_name', ''),
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      ''
    )
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

commit;
