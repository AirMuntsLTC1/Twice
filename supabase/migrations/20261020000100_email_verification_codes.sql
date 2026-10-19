begin;

create table if not exists public.email_verification_codes (
  email text primary key,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts integer not null default 0 check (attempts between 0 and 5),
  last_sent_at timestamptz not null default now(),
  user_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.email_verification_codes enable row level security;
revoke all on public.email_verification_codes from anon, authenticated;
grant all on public.email_verification_codes to service_role;

commit;
