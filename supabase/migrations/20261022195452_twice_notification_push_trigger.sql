-- Trigger push delivery for newly inserted notifications.
-- The webhook secret is stored in Supabase Vault, never in this migration.

create extension if not exists pg_net with schema extensions;

create or replace function public.twice_push_on_notification()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $function$
declare
  webhook_secret text;
begin
  select decrypted_secret
    into webhook_secret
    from vault.decrypted_secrets
   where name = 'twice_push_webhook_secret'
   order by created_at desc
   limit 1;

  if webhook_secret is null or webhook_secret = '' then
    raise exception 'Twice push webhook secret is missing from Vault';
  end if;

  perform net.http_post(
    url := 'https://jgqxvqlwnfywzoxbfkpk.supabase.co/functions/v1/twice-send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-twice-push-secret', webhook_secret
    ),
    body := jsonb_build_object(
      'type', 'INSERT',
      'table', 'notifications',
      'schema', 'public',
      'record', to_jsonb(NEW)
    )
  );

  return NEW;
end;
$function$;

drop trigger if exists twice_push_on_notification on public.notifications;

create trigger twice_push_on_notification
  after insert on public.notifications
  for each row
  execute function public.twice_push_on_notification();

revoke all on function public.twice_push_on_notification()
  from public, anon, authenticated;
