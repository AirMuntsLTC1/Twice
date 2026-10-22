-- Extend notification types + notify when someone saves a post.
-- Safe to re-run.

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (
  type = any (array[
    'follow','follow_request','follow_accept','like','comment','reply',
    'message','story_reaction','story_reply','save'
  ]::text[])
);

create or replace function public.twice_notify_save() returns trigger
language plpgsql security definer set search_path = '' as $$
declare owner uuid;
begin
  select user_id into owner from public.posts where id = new.post_id;
  if owner is null or owner = new.user_id then
    return new;
  end if;
  delete from public.notifications
   where recipient_id = owner
     and actor_id = new.user_id
     and type = 'save'
     and post_id = new.post_id;
  insert into public.notifications (recipient_id, actor_id, type, post_id)
  values (owner, new.user_id, 'save', new.post_id);
  return new;
end $$;

create or replace function public.twice_unnotify_save() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.notifications
   where actor_id = old.user_id
     and type = 'save'
     and post_id = old.post_id;
  return old;
end $$;

drop trigger if exists twice_save_notify on public.saved_posts;
create trigger twice_save_notify after insert on public.saved_posts
  for each row execute function public.twice_notify_save();

drop trigger if exists twice_save_unnotify on public.saved_posts;
create trigger twice_save_unnotify after delete on public.saved_posts
  for each row execute function public.twice_unnotify_save();

revoke all on function public.twice_notify_save(), public.twice_unnotify_save()
  from public, anon, authenticated;
