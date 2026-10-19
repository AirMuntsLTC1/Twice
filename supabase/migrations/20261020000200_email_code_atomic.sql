begin;

create or replace function public.twice_issue_email_code(
  p_email text,
  p_code_hash text,
  p_expires_at timestamptz,
  p_metadata jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_last timestamptz;
begin
  insert into public.email_verification_codes
    (email, code_hash, expires_at, attempts, last_sent_at, user_metadata)
  values
    (lower(trim(p_email)), p_code_hash, p_expires_at, 0, now(),
     coalesce(p_metadata, '{}'::jsonb))
  on conflict (email) do nothing;

  if found then
    return true;
  end if;

  update public.email_verification_codes
  set code_hash = p_code_hash,
      expires_at = p_expires_at,
      attempts = 0,
      last_sent_at = now(),
      user_metadata = coalesce(p_metadata, '{}'::jsonb)
  where email = lower(trim(p_email))
    and last_sent_at <= now() - interval '60 seconds';

  return found;
end;
$$;

create or replace function public.twice_consume_email_code(
  p_email text,
  p_code_hash text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_expiry timestamptz;
  v_attempts integer;
begin
  select code_hash, expires_at, attempts
  into v_hash, v_expiry, v_attempts
  from public.email_verification_codes
  where email = lower(trim(p_email))
  for update;

  if not found or v_expiry <= now() or v_attempts >= 5 then
    return false;
  end if;

  if v_hash <> p_code_hash then
    update public.email_verification_codes
    set attempts = attempts + 1
    where email = lower(trim(p_email));
    return false;
  end if;

  delete from public.email_verification_codes
  where email = lower(trim(p_email));

  return true;
end;
$$;

revoke all on function public.twice_issue_email_code(text,text,timestamptz,jsonb)
  from public, anon, authenticated;
revoke all on function public.twice_consume_email_code(text,text)
  from public, anon, authenticated;

grant execute on function public.twice_issue_email_code(text,text,timestamptz,jsonb)
  to service_role;
grant execute on function public.twice_consume_email_code(text,text)
  to service_role;

commit;
