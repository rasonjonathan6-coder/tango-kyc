-- A user may reply on a ticket only once its payment is confirmed.
--
-- Business rule (server side, never trusted from the client):
--   * the request owes a payment (`payment_required` true) and that payment has
--     not been validated yet (`is_submitted` false) -> the owner cannot reply;
--   * once the payment is approved the derived state flips to submitted and the
--     composer is available again;
--   * when no payment is required the owner replies freely, as before.
--
-- `is_submitted` is derived exactly like `kyc_submission_state` derives it:
-- payments off, or an approved `mvola_payments` row for this ticket. The state
-- is read inside the same `select ... for update` as the ownership and status
-- checks, so a payment approved or a ticket closed between the read and the
-- insert cannot slip through.
--
-- The other guards are preserved verbatim: authentication, ticket ownership,
-- the closed-ticket rule, the per-minute rate limit and the 20 000-char cap.
-- `admin_post_message` is deliberately untouched: the payment gate applies to
-- the request owner only.
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
  v_payment_required boolean;
  v_is_submitted boolean;
  v_recent int;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;
  if v_body is null then
    raise exception 'MESSAGE_REQUIRED' using errcode = '22023';
  end if;

  select user_id,
         status,
         payment_required,
         (not payment_required) or exists (
           select 1
             from public.mvola_payments p
            where p.ticket_id = kyc_requests.id
              and p.status = 'approved'
         )
    into v_owner, v_status, v_payment_required, v_is_submitted
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
  if v_payment_required and not v_is_submitted then
    raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = 'P0003';
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
