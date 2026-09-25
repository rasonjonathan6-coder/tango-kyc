-- Tango KYC Verification - email ingestion, reply matching and admin actions.
-- Every function here runs with elevated rights and is granted to service_role
-- (Edge Functions) or to authenticated admins, never to anonymous clients.

-- ---------------------------------------------------------------------------
-- Idempotent provider event log. Returns the existing row when the provider
-- re-delivers the same event.
-- ---------------------------------------------------------------------------
create or replace function public.record_email_event(
  p_provider text,
  p_external_id text,
  p_event_type text,
  p_payload_hash text default null,
  p_ticket_id uuid default null
)
returns public.email_events
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.email_events;
  v_inserted boolean := false;
begin
  insert into public.email_events (provider, external_id, event_type, payload_hash, ticket_id)
  values (p_provider, p_external_id, p_event_type, p_payload_hash, p_ticket_id)
  on conflict (provider, external_id, event_type) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row
      from public.email_events
     where provider = p_provider and external_id = p_external_id and event_type = p_event_type;
  else
    v_inserted := true;
  end if;

  v_row.payload_hash := coalesce(v_row.payload_hash, p_payload_hash);
  return v_row;
end;
$$;

revoke all on function public.record_email_event(text, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.record_email_event(text, text, text, text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Ticket resolution for an inbound reply.
-- Order: 1) ticket code in subject/body  2) reply token in recipients
--        3) recorded thread / outbound message id in In-Reply-To/References
-- Returns null when nothing matches with certainty.
-- ---------------------------------------------------------------------------
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

  -- 3. Thread continuity via stored message ids.
  v_ids := regexp_matches(coalesce(p_in_reply_to, '') || ' ' || coalesce(p_references, ''), '<[^>]+>', 'g');
  if array_length(v_ids, 1) is null then
    v_ids := regexp_matches(coalesce(p_in_reply_to, '') || ' ' || coalesce(p_references, ''), '[^\s<>,]+@[^\s<>,]+', 'g');
  end if;

  if array_length(v_ids, 1) is not null then
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

revoke all on function public.resolve_ticket_for_reply(text, text, text[], text, text) from public, anon, authenticated;
grant execute on function public.resolve_ticket_for_reply(text, text, text[], text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Store an inbound admin reply against a resolved ticket.
-- Idempotent on (provider message id).
-- ---------------------------------------------------------------------------
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

revoke all on function public.record_inbound_reply(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.record_inbound_reply(uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Quarantine a reply we cannot attribute with certainty.
-- ---------------------------------------------------------------------------
create or replace function public.record_unmatched_reply(
  p_provider text,
  p_external_id text,
  p_from_email text,
  p_to_email text,
  p_subject text,
  p_body_excerpt text,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.unmatched_replies (
    provider, external_id, from_email, to_email, subject, body_excerpt, reason
  ) values (
    p_provider, p_external_id, p_from_email, p_to_email, p_subject,
    left(coalesce(p_body_excerpt, ''), 2000), p_reason
  )
  on conflict (provider, external_id) do update
    set reason = excluded.reason,
        body_excerpt = excluded.body_excerpt
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.record_unmatched_reply(text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.record_unmatched_reply(text, text, text, text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Record the outbound admin notification so threading works for the reply.
-- ---------------------------------------------------------------------------
create or replace function public.record_outbound_email(
  p_ticket_id uuid,
  p_provider_message_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.kyc_requests
     set last_outbound_message_id = coalesce(p_provider_message_id, last_outbound_message_id),
         status = case when status = 'pending' then 'in_review'::public.kyc_status else status end
   where id = p_ticket_id;
end;
$$;

revoke all on function public.record_outbound_email(uuid, text) from public, anon, authenticated;
grant execute on function public.record_outbound_email(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Admin actions from the dashboard
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_status(p_ticket_id uuid, p_status public.kyc_status)
returns public.kyc_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.kyc_requests;
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.kyc_requests set status = p_status where id = p_ticket_id returning * into v_row;
  if v_row.id is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;

revoke all on function public.admin_set_status(uuid, public.kyc_status) from public, anon;
grant execute on function public.admin_set_status(uuid, public.kyc_status) to authenticated, service_role;

create or replace function public.admin_post_message(p_ticket_id uuid, p_body text)
returns public.messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.messages;
  v_body text := nullif(trim(coalesce(p_body, '')), '');
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_body is null then
    raise exception 'MESSAGE_REQUIRED' using errcode = '22023';
  end if;
  insert into public.messages (ticket_id, sender_type, body)
  values (p_ticket_id, 'admin', left(v_body, 20000))
  returning * into v_row;

  update public.kyc_requests
     set status = 'replied', last_reply_at = now()
   where id = p_ticket_id;

  return v_row;
end;
$$;

revoke all on function public.admin_post_message(uuid, text) from public, anon;
grant execute on function public.admin_post_message(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- User reply on their own ticket (ownership enforced server side).
-- ---------------------------------------------------------------------------
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
  v_recent int;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;
  if v_body is null then
    raise exception 'MESSAGE_REQUIRED' using errcode = '22023';
  end if;

  select user_id into v_owner from public.kyc_requests where id = p_ticket_id;
  if v_owner is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_owner <> auth.uid() then
    raise exception 'FORBIDDEN' using errcode = '42501';
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

-- ---------------------------------------------------------------------------
-- Attach a quarantined reply to the correct ticket (admin decision).
-- Stores the excerpt as a real admin message so the user sees it in the
-- dashboard, and marks the quarantine row resolved.
-- ---------------------------------------------------------------------------
create or replace function public.admin_resolve_unmatched_reply(
  p_unmatched_id uuid,
  p_ticket_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unmatched public.unmatched_replies;
  v_msg_id uuid;
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_unmatched from public.unmatched_replies where id = p_unmatched_id;
  if not found then
    raise exception 'UNMATCHED_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.kyc_requests where id = p_ticket_id) then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;

  if coalesce(trim(v_unmatched.body_excerpt), '') <> '' then
    insert into public.messages (ticket_id, sender_type, body, external_message_id)
    values (p_ticket_id, 'admin', left(v_unmatched.body_excerpt, 20000),
            v_unmatched.provider || ':' || v_unmatched.external_id)
    returning id into v_msg_id;

    update public.kyc_requests
       set status = 'replied', last_reply_at = now()
     where id = p_ticket_id;
  end if;

  update public.unmatched_replies
     set resolved_ticket_id = p_ticket_id, resolved_at = now()
   where id = p_unmatched_id;

  return jsonb_build_object('message_id', v_msg_id, 'ticket_id', p_ticket_id);
end;
$$;

revoke all on function public.admin_resolve_unmatched_reply(uuid, uuid) from public, anon;
grant execute on function public.admin_resolve_unmatched_reply(uuid, uuid) to authenticated, service_role;
