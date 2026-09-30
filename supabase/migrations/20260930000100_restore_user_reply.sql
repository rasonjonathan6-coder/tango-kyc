-- Corrective migration.
--
-- An earlier, unrequested migration (20260930000000_payment_gate_user_reply.sql)
-- redefined public.user_post_message so that an open ticket whose MVola payment
-- was still pending could not be answered. That gate was never part of the
-- product contract: the Flutter client has no wording for PAYMENT_NOT_CONFIRMED,
-- and the backend suite (tests/db/run_tests.sql) expects the owner to be able to
-- reply on any open ticket. It broke exactly the reported bug: "the user cannot
-- answer their request".
--
-- The harmful migration has been deleted from the tree, but a database that
-- already ran `supabase db push` still holds the gated definition. This
-- migration is versioned after it, so it restores the canonical definition on
-- the next push in every environment, whether or not the bad one was applied.
--
-- Contract, unchanged from 20260929000100_user_reply_closed_guard.sql:
--   * ownership enforced against auth.uid();
--   * read-only once the ticket is closed;
--   * per-minute rate limit;
--   * payment state does NOT gate replies.
create or replace function public.user_post_message(p_ticket_id uuid, p_body text)
returns public.messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.messages;
  v_body text := nullif(trim(coalesce(p_body, '')), '');
  v_owner uuid;
  v_status public.kyc_status;
  v_recent int;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;
  if v_body is null then
    raise exception 'MESSAGE_REQUIRED' using errcode = '22023';
  end if;

  select user_id, status into v_owner, v_status
    from public.kyc_requests
   where id = p_ticket_id
   for update;
  if v_owner is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_owner <> auth.uid() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_status = 'closed' then
    raise exception 'TICKET_CLOSED' using errcode = 'P0001';
  end if;

  select count(*) into v_recent
    from public.messages
   where ticket_id = p_ticket_id
     and sender_type = 'user'
     and created_at > now() - interval '1 minute';
  if v_recent >= 5 then
    raise exception 'RATE_LIMITED' using errcode = 'P0001';
  end if;

  insert into public.messages (ticket_id, sender_type, body)
  values (p_ticket_id, 'user', left(v_body, 20000))
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.user_post_message(uuid, text) from public, anon;
grant execute on function public.user_post_message(uuid, text) to authenticated, service_role;
