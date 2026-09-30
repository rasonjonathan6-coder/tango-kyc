-- A user may reply on a ticket only while it is still open.
--
-- `user_post_message` already proved ownership, but it accepted a reply on a
-- ticket whose status was `closed`. The UI hides the composer in that case, but
-- a client that calls the RPC directly bypassed the rule, so the restriction is
-- moved where it belongs: the database. The status is re-read inside the same
-- statement as the ownership check, so a ticket closed between the read and the
-- insert cannot slip through.
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
  -- Read-only for the owner once closed, regardless of what the client sends.
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
