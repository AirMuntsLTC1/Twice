-- Verified badges. Readable by everyone, writable by nobody from the app.
-- Only the service role / SQL editor / migrations can add or remove a badge.
create table if not exists public.verified_profiles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  verified_at timestamptz not null default now(),
  note text
);

alter table public.verified_profiles enable row level security;

drop policy if exists verified_profiles_read on public.verified_profiles;
create policy verified_profiles_read
  on public.verified_profiles
  for select
  to anon, authenticated
  using (true);

revoke all on public.verified_profiles from anon, authenticated;
grant select on public.verified_profiles to anon, authenticated;

-- Verify the account: wilme_olid / wilmeolid@gmail.com
insert into public.verified_profiles (user_id, note)
select p.id, 'Account owner'
from public.profiles p
join auth.users u on u.id = p.id
where lower(u.email) = 'wilmeolid@gmail.com'
  and p.username = 'wilme_olid'
on conflict (user_id) do nothing;
