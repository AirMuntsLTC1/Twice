-- Fixes: "new row violates row-level security policy for table conversations"
-- (code 42501) when tapping Message on a profile.
--
-- Cause: the app inserts a conversation and reads the new row back
-- (INSERT ... RETURNING). Reading it requires the SELECT policy, which only
-- allows members -- but the creator is not a member until the next step.
-- Fix: let the creator read the conversation they created.

begin;

drop policy if exists "conversations_read_creator" on public.conversations;
create policy "conversations_read_creator"
on public.conversations for select to authenticated
using (created_by = (select auth.uid()));

commit;
