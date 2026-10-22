-- Twice notification reliability foundation: token registry for FCM-capable clients.
-- This migration alone does not send push notifications; Firebase client setup and
-- a trusted server-side sender are required. Never store FCM service-account secrets here.
begin;

create table if not exists public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null unique,
  platform text not null check (platform in ('android','ios','web')),
  device_label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists device_push_tokens_user_updated_idx
  on public.device_push_tokens (user_id, updated_at desc);

alter table public.device_push_tokens enable row level security;
revoke all on public.device_push_tokens from anon, public;
grant select, insert, update, delete on public.device_push_tokens to authenticated;

drop policy if exists device_push_tokens_select_own on public.device_push_tokens;
create policy device_push_tokens_select_own on public.device_push_tokens
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists device_push_tokens_insert_own on public.device_push_tokens;
create policy device_push_tokens_insert_own on public.device_push_tokens
  for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists device_push_tokens_update_own on public.device_push_tokens;
create policy device_push_tokens_update_own on public.device_push_tokens
  for update to authenticated using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
drop policy if exists device_push_tokens_delete_own on public.device_push_tokens;
create policy device_push_tokens_delete_own on public.device_push_tokens
  for delete to authenticated using (user_id = (select auth.uid()));

commit;
