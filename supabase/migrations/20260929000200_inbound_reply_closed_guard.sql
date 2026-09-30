-- Inbound email replies must respect the closed-ticket rule, and thread
-- resolution must not crash on a real mail client's multi-id headers.
--
-- Two independent defects are fixed here, both on the inbound reply path:
--
-- 1. `resolve_ticket_for_reply` step 3 assigned the set-returning
--    `regexp_matches(..., 'g')` straight into a `text[]` scalar. As soon as
--    `In-Reply-To`/`References` carried two or more ids — the normal case, since
--    mail clients accumulate a `References` chain — the assignment raised
--    `query returned more than one row`, the webhook answered 500 and the
--    provider retried the same event forever. The array is now built with a
--    subquery, so any number of ids is accepted.
--
-- 2. `record_inbound_reply` had no status guard: a reply that arrived after the
--    ticket was closed was stored and moved the ticket back to `replied`,
--    bypassing the read-only rule that `user_post_message` already enforces for
--    the in-app path. The status is now re-read in the same statement and a
--    closed ticket raises `TICKET_CLOSED`; the ticket is never reopened and no
--    message is stored.

create or replace function public.resolve_ticket_for_reply(
  p_subject text,
  p_body text,
  p_recipients text[],
  p_in_reply_to text default null,
  p_references text default null
)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_match text;
  v_token text;
  v_ticket_id uuid;
  v_haystack text;
  v_ids text[];
begin
  -- 1. Explicit ticket code.
  v_haystack := coalesce(p_subject, '') || ' ' || coalesce(p_body, '');
  v_match := (regexp_match(upper(v_haystack), '(TNG-KYC-[0-9A-F]{8})'))[1];
  if v_match is not null then
    select id into v_ticket_id from public.kyc_requests where ticket_code = v_match;
    if v_ticket_id is not null then
      return v_ticket_id;
    end if;
  end if;

  -- 2. reply+<token>@domain routing address.
  if p_recipients is not null then
    foreach v_haystack in array p_recipients loop
      v_token := (regexp_match(lower(v_haystack), 'reply\+([0-9a-f]{32})@'))[1];
      if v_token is not null then
        select id into v_ticket_id from public.kyc_requests where reply_token = v_token;
        if v_ticket_id is not null then
          return v_ticket_id;
        end if;
      end if;
    end loop;
  end if;

  -- 3. Thread continuity via stored message ids. Any number of ids is accepted:
  -- a real `References` header carries a whole chain, not a single id.
  v_ids := array(
    select m[1]
      from regexp_matches(
        coalesce(p_in_reply_to, '') || ' ' || coalesce(p_references, ''), '<[^>]+>', 'g'
      ) as m
  );
  if coalesce(array_length(v_ids, 1), 0) = 0 then
    v_ids := array(
      select m[1]
        from regexp_matches(
          coalesce(p_in_reply_to, '') || ' ' || coalesce(p_references, ''),
          '[^\s<>,]+@[^\s<>,]+', 'g'
        ) as m
    );
  end if;

  if coalesce(array_length(v_ids, 1), 0) > 0 then
    select r.id into v_ticket_id
      from public.kyc_requests r
     where r.last_outbound_message_id = any (v_ids)
        or r.email_thread_id = any (v_ids)
     order by r.created_at desc
     limit 1;
    if v_ticket_id is not null then
      return v_ticket_id;
    end if;

    -- Also try matching a previously stored admin message id.
    select m.ticket_id into v_ticket_id
      from public.messages m
     where m.external_message_id = any (v_ids)
     order by m.created_at desc
     limit 1;
    if v_ticket_id is not null then
      return v_ticket_id;
    end if;
  end if;

  return null;
end;
$$;

revoke all on function public.resolve_ticket_for_reply(text, text, text[], text, text)
  from public, anon, authenticated;
grant execute on function public.resolve_ticket_for_reply(text, text, text[], text, text)
  to service_role;

-- Same body as the original, plus the closed-ticket guard. The duplicate check
-- stays first so a redelivery of an already-stored reply is still reported as a
-- duplicate, even if the ticket closed in the meantime.
create or replace function public.record_inbound_reply(
  p_ticket_id uuid,
  p_clean_body text,
  p_external_message_id text,
  p_from_email text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.messages;
  v_msg_id uuid;
  v_body text := nullif(trim(coalesce(p_clean_body, '')), '');
  v_status public.kyc_status;
begin
  if p_ticket_id is null then
    raise exception 'TICKET_REQUIRED' using errcode = '22023';
  end if;

  if v_body is null then
    v_body := '(empty reply)';
  end if;
  if char_length(v_body) > 20000 then
    v_body := left(v_body, 20000);
  end if;

  if p_external_message_id is not null then
    select * into v_existing from public.messages where external_message_id = p_external_message_id;
    if found then
      return jsonb_build_object('duplicate', true, 'message_id', v_existing.id, 'ticket_id', v_existing.ticket_id);
    end if;
  end if;

  -- A closed ticket is read-only, whatever route the reply arrives by. The
  -- status is read under `for update` so a ticket closed concurrently cannot
  -- slip a message in, and the ticket is never moved back to `replied`.
  select status into v_status from public.kyc_requests where id = p_ticket_id for update;
  if v_status is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_status = 'closed' then
    raise exception 'TICKET_CLOSED' using errcode = 'P0001';
  end if;

  insert into public.messages (ticket_id, sender_type, body, external_message_id)
  values (p_ticket_id, 'admin', v_body, p_external_message_id)
  returning id into v_msg_id;

  update public.kyc_requests
     set status = 'replied',
         last_reply_at = now(),
         email_thread_id = coalesce(email_thread_id, p_external_message_id)
   where id = p_ticket_id;

  return jsonb_build_object('duplicate', false, 'message_id', v_msg_id, 'ticket_id', p_ticket_id);
exception
  when unique_violation then
    select * into v_existing from public.messages where external_message_id = p_external_message_id;
    return jsonb_build_object('duplicate', true, 'message_id', v_existing.id, 'ticket_id', v_existing.ticket_id);
end;
$$;

revoke all on function public.record_inbound_reply(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.record_inbound_reply(uuid, text, text, text) to service_role;
