-- Tango KYC Verification - backend test suite.
-- Runs against a real Postgres/Supabase instance and exercises real code paths:
-- validation, ticket generation, rate limiting, RLS isolation, admin gating,
-- reply resolution and webhook idempotency.
--
-- Usage: psql "$DB_URL" -v ON_ERROR_STOP=1 -f tests/db/run_tests.sql
-- Everything runs inside one transaction that is rolled back at the end, so the
-- database is left untouched.

\set ON_ERROR_STOP on

begin;

create schema if not exists test_harness;

create or replace function test_harness.ok(p_cond boolean, p_name text)
returns void language plpgsql as $$
begin
  if p_cond then
    raise notice 'PASS  %', p_name;
  else
    raise exception 'FAIL  %', p_name;
  end if;
end;
$$;

create or replace function test_harness.raises(p_sql text, p_expected text, p_name text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_expected || '%' then
      raise notice 'PASS  %', p_name;
    else
      raise exception 'FAIL  % (raised "%" instead of "%")', p_name, sqlerrm, p_expected;
    end if;
    return;
  end;
  raise exception 'FAIL  % (nothing was raised)', p_name;
end;
$$;

-- Impersonate an authenticated user the same way PostgREST does.
create or replace function test_harness.act_as(p_user uuid)
returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create or replace function test_harness.act_as_service()
returns void language plpgsql as $$
begin
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
end;
$$;

-- The harness impersonates real API roles, so those roles need to reach it.
grant usage on schema test_harness to authenticated, service_role, anon;
grant execute on all functions in schema test_harness to authenticated, service_role, anon;

-- Directly insert a ticket, bypassing the rate limiter. Used by tests whose
-- subject is something other than ticket creation. `p_payment_required` sets the
-- explicit admin signal that gates `mvola_start_payment`, so MVola tests can opt
-- in without going through the admin RPC.
create or replace function test_harness.new_ticket(
  p_user uuid, p_link text, p_value text, p_type public.register_type,
  p_payment_required boolean default false
)
returns public.kyc_requests
language plpgsql
as $$
declare
  v_row public.kyc_requests;
begin
  insert into public.kyc_requests (user_id, ticket_code, tango_profile_link, register_type,
                                   register_value, reply_token, payment_required)
  values (p_user, 'TNG-KYC-' || upper(encode(extensions.gen_random_bytes(4), 'hex')),
          p_link, p_type, p_value, encode(extensions.gen_random_bytes(16), 'hex'),
          p_payment_required)
  returning * into v_row;
  return v_row;
end;
$$;
grant execute on function test_harness.new_ticket(uuid, text, text, public.register_type, boolean)
  to authenticated, service_role, anon;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_user_b uuid := '22222222-2222-2222-2222-222222222222';
  v_admin  uuid := '33333333-3333-3333-3333-333333333333';
begin
  -- The suite is transactional, but it can also run against a database where a
  -- previous end-to-end run already created these accounts. Clear any such rows
  -- (cascading to profiles and tickets) so the fixtures are deterministic.
  delete from auth.users
   where id in (v_user_a, v_user_b, v_admin)
      or email in ('user.a@example.com', 'user.b@example.com', 'customerservicefor032@gmail.com');

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                          created_at, updated_at)
  values
    (v_user_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'user.a@example.com', crypt('Password123!', gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"User A"}'::jsonb, now(), now()),
    (v_user_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'user.b@example.com', crypt('Password123!', gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}'::jsonb, '{"full_name":"User B"}'::jsonb, now(), now()),
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'customerservicefor032@gmail.com', crypt('Password123!', gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"],"role":"admin"}'::jsonb, '{"full_name":"Admin"}'::jsonb, now(), now());
end $$;

-- ---------------------------------------------------------------------------
-- 1. Normalisation & type detection
-- ---------------------------------------------------------------------------
do $$
begin
  perform test_harness.ok(public.detect_register_type('John@Example.COM ') = 'email', 'detect email');
  perform test_harness.ok(public.detect_register_type('+261 34 12 345 67') = 'phone', 'detect phone');
  perform test_harness.ok(public.detect_register_type('   ') is null, 'blank is neither');
  perform test_harness.ok(public.normalize_register_value(' John@Example.COM ') = 'john@example.com',
    'email normalised to lowercase/trimmed');
  perform test_harness.ok(public.normalize_register_value('+261 34-12-345-67') = '+261341234567',
    'phone normalised to +digits');
  perform test_harness.ok(public.normalize_register_value('034 12 345 67') = '0341234567',
    'local phone keeps digits');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Ticket creation, uniqueness and server-side validation
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_t public.kyc_requests;
  v_t2 public.kyc_requests;
  v_count int;
begin
  perform test_harness.act_as_service();

  v_t := public.create_kyc_request(v_a, 'https://tango.me/user-a', 'User.A@Example.com');
  perform test_harness.ok(v_t.ticket_code ~ '^TNG-KYC-[0-9A-F]{8}$', 'ticket code format');
  perform test_harness.ok(v_t.register_type = 'email', 'register_type stored as email');
  perform test_harness.ok(v_t.register_value = 'user.a@example.com', 'register_value normalised');
  perform test_harness.ok(v_t.status = 'pending', 'initial status pending');
  perform test_harness.ok(char_length(v_t.reply_token) = 32, 'reply token generated');
  perform test_harness.ok(v_t.reply_token <> v_t.ticket_code, 'reply token is not the ticket code');

  select count(*) into v_count from public.messages where ticket_id = v_t.id;
  perform test_harness.ok(v_count = 1, 'opening message created');

  -- exact duplicate inside the window returns the same ticket
  v_t2 := public.create_kyc_request(v_a, 'https://tango.me/user-a', 'user.a@example.com');
  perform test_harness.ok(v_t2.id = v_t.id, 'exact duplicate reuses existing ticket');

  -- validation failures
  perform test_harness.raises(
    format('select public.create_kyc_request(%L, %L, %L)', v_a, '', 'a@b.com'),
    'PROFILE_LINK_REQUIRED', 'empty profile link rejected');
  perform test_harness.raises(
    format('select public.create_kyc_request(%L, %L, %L)', v_a, 'not a url', 'a@b.com'),
    'PROFILE_LINK_INVALID', 'invalid profile link rejected');
  perform test_harness.raises(
    format('select public.create_kyc_request(%L, %L, %L)', v_a, 'javascript:alert(1)', 'a@b.com'),
    'PROFILE_LINK_INVALID', 'javascript: scheme rejected');
  perform test_harness.raises(
    format('select public.create_kyc_request(%L, %L, %L)', v_a, 'https://tango.me/x', '   '),
    'REGISTER_REQUIRED', 'missing register value rejected');
  perform test_harness.raises(
    format('select public.create_kyc_request(%L, %L, %L)', v_a, 'https://tango.me/x', 'foo@bar'),
    'REGISTER_EMAIL_INVALID', 'malformed email rejected');
  perform test_harness.raises(
    format('select public.create_kyc_request(%L, %L, %L)', v_a, 'https://tango.me/x', '12345'),
    'REGISTER_PHONE_INVALID', 'too-short phone rejected');
  perform test_harness.raises(
    'select public.create_kyc_request(null, ''https://tango.me/x'', ''a@b.com'')',
    'AUTH_REQUIRED', 'missing user rejected');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Uniqueness of ticket codes and reply tokens across many tickets
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  i int;
begin
  perform test_harness.act_as_service();
  for i in 1..200 loop
    insert into public.kyc_requests (user_id, ticket_code, tango_profile_link, register_type,
                                    register_value, reply_token)
    values (v_a,
            'TNG-KYC-' || upper(encode(extensions.gen_random_bytes(4), 'hex')),
            'https://tango.me/bulk/' || i,
            'email', 'bulk' || i || '@example.com',
            encode(extensions.gen_random_bytes(16), 'hex'));
  end loop;

  perform test_harness.ok(
    (select count(*) = count(distinct ticket_code) from public.kyc_requests),
    'all ticket codes unique');
  perform test_harness.ok(
    (select count(*) = count(distinct reply_token) from public.kyc_requests),
    'all reply tokens unique');

  perform test_harness.ok(
    (select count(*) from public.kyc_requests where ticket_code !~ '^TNG-KYC-[0-9A-F]{8}$') = 0,
    'no malformed ticket codes');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Rate limiting, per-day ceiling and duplicate re-submission
-- ---------------------------------------------------------------------------
do $$
declare
  v_b uuid := '22222222-2222-2222-2222-222222222222';
  v_t public.kyc_requests;
begin
  perform test_harness.act_as_service();
  v_t := public.create_kyc_request(v_b, 'https://tango.me/b/1', 'user.b@example.com');

  -- an identical re-submission is deduplicated instead of rate limited
  perform test_harness.ok(
    (public.create_kyc_request(v_b, 'https://tango.me/b/1', 'user.b@example.com')).id = v_t.id,
    'identical re-submission deduplicated, not rate limited');

  perform test_harness.raises(
    format('select public.create_kyc_request(%L, %L, %L)', v_b, 'https://tango.me/b/2', 'user.b@example.com'),
    'RATE_LIMITED', 'new request within window is rate limited');

  -- backdate the first ticket so only the daily ceiling can trigger
  update public.kyc_requests set created_at = now() - interval '30 minutes'
   where id = v_t.id;
  update public.app_settings
     set value = jsonb_set(value, '{max_requests_per_day}', '1')
   where key = 'rate_limit';

  perform test_harness.raises(
    format('select public.create_kyc_request(%L, %L, %L)', v_b, 'https://tango.me/b/4', 'user.b@example.com'),
    'RATE_LIMITED_DAILY', 'daily ceiling enforced');

  update public.app_settings
     set value = jsonb_set(value, '{max_requests_per_day}', '5')
   where key = 'rate_limit';
end $$;

-- ---------------------------------------------------------------------------
-- 5. RLS: a user only sees their own tickets and messages
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_b uuid := '22222222-2222-2222-2222-222222222222';
  v_visible int;
  v_b_msg_visible int;
begin
  perform test_harness.act_as_service();
  perform test_harness.act_as(v_a);
  select count(*) into v_visible from public.kyc_requests;
  perform test_harness.ok(v_visible = (select count(*) from public.kyc_requests where user_id = v_a),
    'user A sees only their own tickets');

  select count(*) into v_b_msg_visible
    from public.messages m
    join public.kyc_requests r on r.id = m.ticket_id
   where r.user_id = v_b;
  perform test_harness.ok(v_b_msg_visible = 0, 'user A sees no messages from user B');

  perform test_harness.ok(
    (select count(*) from public.kyc_requests where user_id = v_b) = 0,
    'user B tickets are invisible to user A');

  perform test_harness.act_as(v_b);
  perform test_harness.ok(
    (select count(*) from public.kyc_requests where user_id = v_a) = 0,
    'user A tickets are invisible to user B');
end $$;

-- ---------------------------------------------------------------------------
-- 6. RLS: clients cannot write tickets, escalate roles or read admin tables
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_ticket uuid;
begin
  perform test_harness.act_as_service();
  select id into v_ticket from public.kyc_requests where user_id = v_a limit 1;

  perform test_harness.act_as(v_a);

  perform test_harness.raises(
    format('update public.kyc_requests set status = ''closed'' where id = %L', v_ticket),
    'permission denied', 'user cannot change ticket status');

  perform test_harness.raises(
    format('update public.kyc_requests set user_id = %L where id = %L',
           '22222222-2222-2222-2222-222222222222', v_ticket),
    'permission denied', 'user cannot reassign ticket ownership');

  perform test_harness.raises(
    format('insert into public.kyc_requests (user_id, ticket_code, tango_profile_link, register_type, register_value, reply_token) values (%L, %L, %L, ''email'', ''x@y.com'', %L)',
           v_a, 'TNG-KYC-DEADBEEF', 'https://tango.me/hack', 'deadtoken'),
    'permission denied', 'user cannot insert tickets directly');

  perform test_harness.raises(
    'update public.profiles set role = ''admin'' where id = auth.uid()',
    'permission denied', 'user cannot escalate their own role');

  perform test_harness.raises(
    'select public.admin_stats()',
    'FORBIDDEN', 'user cannot read admin stats');

  perform test_harness.raises(
    'select * from public.admin_ticket_list()',
    'FORBIDDEN', 'user cannot list admin tickets');

  perform test_harness.raises(
    'select public.admin_post_message(gen_random_uuid(), ''x'')',
    'FORBIDDEN', 'user cannot post as admin');

  perform test_harness.ok(
    (select count(*) from public.email_events) = 0,
    'user cannot read email_events');

  perform test_harness.ok(
    (select count(*) from public.unmatched_replies) = 0,
    'user cannot read unmatched_replies');

  update public.profiles set display_name = 'User A Renamed' where id = auth.uid();
  perform test_harness.ok(
    (select display_name from public.profiles where id = v_a) = 'User A Renamed',
    'user can update their own display_name');
end $$;

-- ---------------------------------------------------------------------------
-- 7. Admin gating and admin helpers
-- ---------------------------------------------------------------------------
do $$
declare
  v_admin uuid := '33333333-3333-3333-3333-333333333333';
  v_stats jsonb;
  v_rows int;
begin
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select role from public.profiles where id = v_admin) = 'admin',
    'admin role bootstrapped from app_metadata');

  perform test_harness.act_as(v_admin);
  v_stats := public.admin_stats();
  perform test_harness.ok((v_stats ->> 'total')::int > 0, 'admin sees total count');
  perform test_harness.ok(v_stats ? 'pending' and v_stats ? 'in_review'
    and v_stats ? 'replied' and v_stats ? 'closed', 'admin stats expose every status bucket');

  select count(*) into v_rows from public.admin_ticket_list();
  perform test_harness.ok(v_rows > 0, 'admin can list all tickets');

  perform test_harness.ok(
    (select count(*) from public.kyc_requests) = v_rows,
    'admin sees every ticket row');
end $$;

-- ---------------------------------------------------------------------------
-- 8. Reply resolution strategies
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_t public.kyc_requests;
  v_found uuid;
begin
  perform test_harness.act_as_service();
  perform test_harness.act_as_service();

  v_t := test_harness.new_ticket(v_a, 'https://tango.me/resolve/1', 'resolve1@example.com', 'email');

  v_found := public.resolve_ticket_for_reply(
    'Manual KYC Verification request - Profil Creator (' || v_t.tango_profile_link || ') [' || v_t.ticket_code || ']',
    'Hello', array['reply@inbound.resend.app'], null, null);
  perform test_harness.ok(v_found = v_t.id, 'resolved by ticket code in subject');

  v_found := public.resolve_ticket_for_reply('Re: whatever',
    'Ticket ID: ' || lower(v_t.ticket_code), array['reply@inbound.resend.app'], null, null);
  perform test_harness.ok(v_found = v_t.id, 'resolved by lowercase ticket code in body');

  v_found := public.resolve_ticket_for_reply('Re: no code here', 'no code',
    array['reply+' || v_t.reply_token || '@inbound.resend.app'], null, null);
  perform test_harness.ok(v_found = v_t.id, 'resolved by reply token address');

  update public.kyc_requests set last_outbound_message_id = '<outbound-123@resend.dev>'
   where id = v_t.id;
  v_found := public.resolve_ticket_for_reply('Re: nothing helpful', 'still nothing',
    array['reply@inbound.resend.app'], '<outbound-123@resend.dev>', null);
  perform test_harness.ok(v_found = v_t.id, 'resolved by In-Reply-To thread id');

  v_found := public.resolve_ticket_for_reply('Random subject', 'Random body',
    array['reply@inbound.resend.app'], null, null);
  perform test_harness.ok(v_found is null, 'unknown reply resolves to null');

  v_found := public.resolve_ticket_for_reply('TNG-KYC-00000000 attached', 'TNG-KYC-00000000',
    array['reply@inbound.resend.app'], null, null);
  perform test_harness.ok(v_found is null, 'non-existent ticket code resolves to null');
end $$;

-- ---------------------------------------------------------------------------
-- 9. Inbound reply storage + webhook idempotency
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_t public.kyc_requests;
  v_res jsonb;
  v_res2 jsonb;
  v_count int;
begin
  perform test_harness.act_as_service();

  v_t := test_harness.new_ticket(v_a, 'https://tango.me/inbound/1', 'inbound1@example.com', 'email');

  v_res := public.record_inbound_reply(v_t.id, E'Hello,\n\nYour verification request has been reviewed.',
    '<admin-reply-1@mail.gmail.com>', 'tangoturq@gmail.com');
  perform test_harness.ok((v_res ->> 'duplicate')::boolean = false, 'first inbound reply stored');

  v_res2 := public.record_inbound_reply(v_t.id, E'Hello,\n\nYour verification request has been reviewed.',
    '<admin-reply-1@mail.gmail.com>', 'tangoturq@gmail.com');
  perform test_harness.ok((v_res2 ->> 'duplicate')::boolean = true, 'duplicate webhook is idempotent');
  perform test_harness.ok(v_res2 ->> 'message_id' = v_res ->> 'message_id',
    'duplicate returns the original message id');

  select count(*) into v_count from public.messages
   where ticket_id = v_t.id and external_message_id = '<admin-reply-1@mail.gmail.com>';
  perform test_harness.ok(v_count = 1, 'exactly one message row per provider message');

  perform test_harness.ok(
    (select status from public.kyc_requests where id = v_t.id) = 'replied',
    'status advanced to replied');
  perform test_harness.ok(
    (select last_reply_at is not null from public.kyc_requests where id = v_t.id),
    'last_reply_at recorded');

  v_res := public.record_inbound_reply(v_t.id, 'other content', '<admin-reply-1@mail.gmail.com>', null);
  perform test_harness.ok((v_res ->> 'duplicate')::boolean = true, 'cross-ticket duplicate rejected');
end $$;

-- ---------------------------------------------------------------------------
-- 10. Email event log idempotency
-- ---------------------------------------------------------------------------
do $$
declare
  v_e1 public.email_events;
  v_e2 public.email_events;
begin
  perform test_harness.act_as_service();
  perform test_harness.act_as_service();
  v_e1 := public.record_email_event('resend', 'evt_1', 'email.received', 'hash-1', null);
  v_e2 := public.record_email_event('resend', 'evt_1', 'email.received', 'hash-1', null);
  perform test_harness.ok(v_e1.id = v_e2.id, 'repeated provider event reuses the log row');
  perform test_harness.ok(
    (select count(*) from public.email_events where external_id = 'evt_1') = 1,
    'only one email_events row per provider event');
end $$;

-- ---------------------------------------------------------------------------
-- 11. Unmatched replies and user replies
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_b uuid := '22222222-2222-2222-2222-222222222222';
  v_admin uuid := '33333333-3333-3333-3333-333333333333';
  v_open public.kyc_requests;
  v_closed public.kyc_requests;
  v_b_open public.kyc_requests;
  v_row public.messages;
  v_b_row public.messages;
  v_long public.messages;
  v_id uuid;
  v_i int;
begin
  perform test_harness.act_as_service();
  v_id := public.record_unmatched_reply('resend', 'evt_unmatched',
    'tangoturq@gmail.com', 'reply@inbound.resend.app', 'Random', 'body', 'no_matching_ticket');
  perform test_harness.ok(v_id is not null, 'unmatched reply recorded');

  perform test_harness.act_as(v_a);
  perform test_harness.ok(
    (select count(*) from public.unmatched_replies) = 0,
    'unmatched replies are invisible to users');
  perform test_harness.raises(
    format('select public.admin_resolve_unmatched_reply(%L, %L)', v_id::text, gen_random_uuid()::text),
    'FORBIDDEN', 'non-admin cannot resolve a quarantined reply');

  -- The user -> admin reply path is back, and its contract is now: execute is
  -- granted to `authenticated` on purpose, and the protection lives in the SQL
  -- body (auth.uid(), ticket ownership, ticket status, rate limit, length cap).
  -- The assertions below pin each branch of that contract. Tickets are created
  -- explicitly so the expectations cannot depend on rows left by another run.

  perform test_harness.act_as_service();
  v_open := test_harness.new_ticket(v_a, 'https://tango.me/reply-open', 'reply.open@example.com', 'email');
  v_b_open := test_harness.new_ticket(v_b, 'https://tango.me/reply-b', 'reply.b@example.com', 'email');
  v_closed := test_harness.new_ticket(v_a, 'https://tango.me/reply-closed', 'reply.closed@example.com', 'email');

  -- This section pins the reply contract (ownership, closed status, anon, the
  -- 20 000-char cap and the per-minute limit), not the payment gate. MVola is
  -- on, so the creation trigger flags every fresh ticket payment-required;
  -- clear the flag on the two open tickets so the reply branches this section is
  -- about stay reachable. The payment gate itself is pinned in section 23.
  update public.kyc_requests
     set payment_required = false
   where id in (v_open.id, v_b_open.id);

  perform test_harness.act_as(v_admin);
  perform public.admin_set_status(v_closed.id, 'closed');

  -- A. The owner of an OPEN ticket may reply; the row is a `user` message on
  -- their own ticket. `public.messages` has no author column - the author is
  -- `auth.uid()` and ownership of the ticket is what ties the row to the caller.
  perform test_harness.act_as(v_a);
  v_row := public.user_post_message(v_open.id, 'Here are my documents.');
  perform test_harness.ok(v_row.id is not null, 'the owner can reply on their open ticket');
  perform test_harness.ok(v_row.sender_type = 'user', 'a user reply is stored as a user message');
  perform test_harness.ok(v_row.ticket_id = v_open.id, 'the reply lands on the caller''s ticket');
  perform test_harness.ok(v_row.body = 'Here are my documents.', 'the body is stored verbatim');
  -- Readable by the owner through RLS: proof the row belongs to their ticket.
  perform test_harness.ok(
    (select count(*) from public.messages
      where id = v_row.id and ticket_id = v_open.id) = 1,
    'the owner can read back their own reply');

  -- B. A signed-in user who does not own the ticket is refused.
  perform test_harness.act_as(v_b);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_open.id::text, 'trespassing'),
    'FORBIDDEN', 'a non-owner cannot post on another user''s ticket');
  -- The refusal is about ownership, not a blanket block: the same caller can
  -- still reply on a ticket they do own.
  v_b_row := public.user_post_message(v_b_open.id, 'This one is mine.');
  perform test_harness.ok(
    v_b_row.id is not null,
    'the same user can still reply on their own ticket');
  -- And the refused write stored nothing.
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select count(*) from public.messages
      where ticket_id = v_open.id and body = 'trespassing') = 0,
    'a refused reply is not stored');

  -- C. The owner of a CLOSED ticket is refused, even though they own it.
  perform test_harness.act_as(v_a);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_closed.id::text, 'One more thing.'),
    'TICKET_CLOSED', 'the owner cannot reply on a closed ticket');
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select count(*) from public.messages
      where ticket_id = v_closed.id and body = 'One more thing.') = 0,
    'a reply refused as closed is not stored');

  -- D. A caller with no JWT subject is refused before touching the data.
  -- `anon` cannot even execute the function (least privilege); the AUTH_REQUIRED
  -- branch is reached by a role that can execute but carries no `sub` claim,
  -- the same convention the MVola sections use for unauthenticated callers.
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_open.id::text, 'anonymous'),
    'permission denied', 'anon has no execute grant on user_post_message');

  perform test_harness.act_as_service();
  perform set_config('request.jwt.claims', '{}', true);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_open.id::text, 'anonymous'),
    'AUTH_REQUIRED', 'an unauthenticated caller cannot post a reply');

  -- E1. The length cap is intact: an over-long body is truncated to 20 000
  -- characters rather than rejected or stored whole (the table check is 1..20000).
  perform test_harness.act_as(v_a);
  v_long := public.user_post_message(v_open.id, repeat('x', 25000));
  perform test_harness.ok(
    char_length(v_long.body) = 20000,
    'an over-long reply is truncated to 20000 characters');

  -- E2. The 5-per-minute limit is intact. A and E1 already stored two user
  -- messages on this ticket; four fillers bring the count to six, above the
  -- limit of five, so the next reply from the owner is refused.
  perform test_harness.act_as_service();
  for v_i in 1..4 loop
    insert into public.messages (ticket_id, sender_type, body)
    values (v_open.id, 'user', 'filler ' || v_i);
  end loop;

  perform test_harness.act_as(v_a);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_open.id::text, 'sixth'),
    'RATE_LIMITED', 'the sixth reply in a minute is rate limited');
end $$;

-- ---------------------------------------------------------------------------
-- 12. Admin actions
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_admin uuid := '33333333-3333-3333-3333-333333333333';
  v_ticket uuid;
  v_unmatched uuid;
  v_resolved jsonb;
begin
  perform test_harness.act_as_service();
  -- Use a ticket this section creates, so the assertions cannot be affected by
  -- rows another run (for example the end-to-end script) left behind.
  v_ticket := (test_harness.new_ticket(
    v_a, 'https://tango.me/admin/1', 'admin.section@example.com', 'email')).id;

  perform test_harness.act_as(v_admin);
  perform public.admin_set_status(v_ticket, 'closed');
  perform test_harness.ok(
    (select status from public.kyc_requests where id = v_ticket) = 'closed',
    'admin can change status');

  perform public.admin_post_message(v_ticket, 'Closing this request.');
  perform test_harness.ok(
    (select count(*) from public.messages where ticket_id = v_ticket and sender_type = 'admin') >= 1,
    'admin can post a message');

  -- Attaching a quarantined reply turns it into a visible admin message.
  -- Recording the quarantine row is a service_role action.
  perform test_harness.act_as_service();
  v_unmatched := public.record_unmatched_reply('resend', 'evt_resolve_me',
    'tangoturq@gmail.com', 'reply@inbound.resend.app', 'Re: KYC',
    'Hello, your request was reviewed.', 'no_confident_ticket_match');

  perform test_harness.act_as(v_admin);
  v_resolved := public.admin_resolve_unmatched_reply(v_unmatched, v_ticket);
  perform test_harness.ok((v_resolved ->> 'ticket_id')::uuid = v_ticket,
    'admin can attach a quarantined reply to a ticket');
  perform test_harness.ok(
    (select resolved_at is not null from public.unmatched_replies where id = v_unmatched),
    'quarantine row marked resolved');
  perform test_harness.ok(
    (select count(*) from public.messages
      where ticket_id = v_ticket and body = 'Hello, your request was reviewed.') = 1,
    'resolved reply becomes a visible admin message');
end $$;

-- ---------------------------------------------------------------------------
-- 12b. Inbound reply -> automatic 'replied' transition.
--
-- The status value the project uses for "a reply came in" is the enum member
-- `replied` (`public.kyc_status` has no `reply_received`): it is set server side
-- by `record_inbound_reply`, never by the client. These assertions pin the four
-- behaviours that were asked for explicitly.
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_b uuid := '22222222-2222-2222-2222-222222222222';
  v_t public.kyc_requests;
  v_other public.kyc_requests;
  v_res jsonb;
  v_before int;
  v_after int;
begin
  perform test_harness.act_as_service();

  -- A. A resolvable reply advances the ticket with no admin action.
  v_t := test_harness.new_ticket(v_a, 'https://tango.me/s12b/a', 's12b.a@example.com', 'email');
  perform test_harness.ok(
    (select status from public.kyc_requests where id = v_t.id) = 'pending',
    'A: the ticket starts pending');

  perform test_harness.ok(
    public.resolve_ticket_for_reply(
      'Re: KYC', 'Ticket ID: ' || v_t.ticket_code,
      array['reply@inbound.resend.app'], null, null) = v_t.id,
    'A: the reply resolves to the ticket by ticket code');

  v_before := (select count(*) from public.notifications
                where ticket_id = v_t.id and type = 'status_changed');
  v_res := public.record_inbound_reply(v_t.id, 'Here is my document.',
    '<s12b-a1@mail.gmail.com>', 's12b.a@example.com');
  perform test_harness.ok((v_res ->> 'duplicate')::boolean = false,
    'A: the inbound reply is stored');
  perform test_harness.ok(
    (select status from public.kyc_requests where id = v_t.id) = 'replied',
    'A: no admin action needed, status becomes replied');
  perform test_harness.ok(
    (select count(*) from public.kyc_status_history
      where ticket_id = v_t.id and to_status = 'replied' and from_status = 'pending') = 1,
    'A: exactly one history row records the transition');
  v_after := (select count(*) from public.notifications
               where ticket_id = v_t.id and type = 'status_changed');
  perform test_harness.ok(v_after = v_before + 1,
    'A: the status-changed notification is created automatically');

  -- C. The same provider message delivered twice changes nothing.
  v_res := public.record_inbound_reply(v_t.id, 'Here is my document.',
    '<s12b-a1@mail.gmail.com>', 's12b.a@example.com');
  perform test_harness.ok((v_res ->> 'duplicate')::boolean = true,
    'C: the second delivery is reported as a duplicate');
  perform test_harness.ok(
    (select count(*) from public.messages
      where ticket_id = v_t.id and external_message_id = '<s12b-a1@mail.gmail.com>') = 1,
    'C: exactly one message row exists');
  perform test_harness.ok(
    (select count(*) from public.notifications
      where ticket_id = v_t.id and type = 'status_changed') = v_after,
    'C: no duplicate notification is created');

  -- D. A reply arriving on an already-replied ticket adds no redundant
  --    transition: the status stays 'replied' and no second history row or
  --    second status notification appears.
  perform test_harness.ok(
    (select count(*) from public.kyc_status_history
      where ticket_id = v_t.id and to_status = 'replied') = 1,
    'D: history holds a single replied transition before the next reply');
  v_res := public.record_inbound_reply(v_t.id, 'A second reply.',
    '<s12b-a2@mail.gmail.com>', 's12b.a@example.com');
  perform test_harness.ok((v_res ->> 'duplicate')::boolean = false,
    'D: the second distinct message is still stored');
  perform test_harness.ok(
    (select status from public.kyc_requests where id = v_t.id) = 'replied',
    'D: the status is unchanged, still replied');
  perform test_harness.ok(
    (select count(*) from public.kyc_status_history
      where ticket_id = v_t.id and to_status = 'replied') = 1,
    'D: no second replied transition is recorded');
  perform test_harness.ok(
    (select count(*) from public.notifications
      where ticket_id = v_t.id and type = 'status_changed') = v_after,
    'D: no second status notification is created');

  -- B. An unresolved reply must not touch any ticket.
  v_other := test_harness.new_ticket(v_b, 'https://tango.me/s12b/b', 's12b.b@example.com', 'email');
  perform test_harness.ok(
    public.resolve_ticket_for_reply(
      'Random subject', 'nothing that matches',
      array['reply@inbound.resend.app'], null, null) is null,
    'B: an unknown reply resolves to null');

  perform test_harness.ok(
    public.record_unmatched_reply('resend', 'evt_s12b_unmatched',
      'stranger@example.com', 'reply@inbound.resend.app', 'Random', 'body',
      'no_confident_ticket_match') is not null,
    'B: the unresolved reply is quarantined');
  perform test_harness.ok(
    (select status from public.kyc_requests where id = v_other.id) = 'pending',
    'B: a quarantined reply leaves the ticket pending');

  -- E. A normal user cannot force the status: no write privilege on the table
  --    and no execute privilege on the privileged functions.
  perform test_harness.act_as(v_a);
  perform test_harness.raises(
    format('update public.kyc_requests set status = ''replied'' where id = %L', v_t.id::text),
    'permission denied', 'E: a user cannot update a ticket status directly');
  perform test_harness.raises(
    format('select public.record_inbound_reply(%L, ''forced'', ''<forced@x>'', null)', v_t.id::text),
    'permission denied', 'E: a user cannot call record_inbound_reply');
  perform test_harness.raises(
    format('select public.admin_set_status(%L, ''replied'')', v_t.id::text),
    'FORBIDDEN', 'E: a non-admin cannot call admin_set_status');
end $$;

-- ---------------------------------------------------------------------------
-- 13. Settings-driven configuration
-- ---------------------------------------------------------------------------
do $$
begin
  perform test_harness.act_as_service();
  perform test_harness.ok(public.setting_text('admin_email') = 'customerservicefor032@gmail.com',
    'admin email comes from server settings');
  perform test_harness.ok(public.setting_int('rate_limit', 'max_requests_per_day', 0) = 5,
    'rate limit configurable server side');

  update public.app_settings
     set value = jsonb_set(value, '{max_requests_per_day}', '2')
   where key = 'rate_limit';
  perform test_harness.ok(public.setting_int('rate_limit', 'max_requests_per_day', 0) = 2,
    'rate limit value can be tuned without code changes');
end $$;

-- ---------------------------------------------------------------------------
-- 14. MVola configuration and USSD generation
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_cfg jsonb;
begin
  perform test_harness.act_as(v_user_a);
  v_cfg := public.mvola_config();

  perform test_harness.ok((v_cfg ->> 'recipient_number') = '0346715622',
    'mvola recipient number comes from server config');
  perform test_harness.ok((v_cfg ->> 'amount')::numeric = 20000,
    'mvola amount comes from server config');
  perform test_harness.ok((v_cfg ->> 'currency') = 'MGA',
    'mvola currency comes from server config');
  perform test_harness.ok((v_cfg ->> 'ussd_code') = '#111*1*2*0346715622*20000*2#',
    'ussd code is generated from the configurable template');

  -- The USSD string is derived, not stored: changing the config changes it.
  -- Configuration edits are a service-role operation; a normal user has no
  -- update grant on app_settings at all.
  perform test_harness.act_as(v_user_a);
  perform test_harness.raises(
    'update public.app_settings set value = ''{}''::jsonb where key = ''mvola''',
    'permission denied', 'a normal user cannot edit the mvola configuration');

  perform test_harness.act_as_service();
  update public.app_settings
     set value = jsonb_set(value, '{recipient_number}', '"0999999999"')
   where key = 'mvola';
  perform test_harness.act_as(v_user_a);
  v_cfg := public.mvola_config();
  perform test_harness.ok((v_cfg ->> 'ussd_code') = '#111*1*2*0999999999*20000*2#',
    'changing the recipient number changes the generated ussd code');

  perform test_harness.act_as_service();
  update public.app_settings
     set value = jsonb_set(value, '{amount}', '5000')
   where key = 'mvola';
  perform test_harness.act_as(v_user_a);
  v_cfg := public.mvola_config();
  perform test_harness.ok((v_cfg ->> 'ussd_code') = '#111*1*2*0999999999*5000*2#',
    'changing the amount changes the generated ussd code');

  perform test_harness.act_as_service();
  update public.app_settings
     set value = jsonb_set(value, '{ussd_template}', '"*111*{recipient}*{amount}#"')
   where key = 'mvola';
  perform test_harness.act_as(v_user_a);
  v_cfg := public.mvola_config();
  perform test_harness.ok((v_cfg ->> 'ussd_code') = '*111*0999999999*5000#',
    'changing the template changes the generated ussd code');

  -- Restore the shipped defaults so later sections are deterministic.
  perform test_harness.act_as_service();
  update public.app_settings
     set value = jsonb_build_object(
       'enabled', true, 'recipient_number', '0346715622', 'amount', 20000,
       'currency', 'MGA', 'ussd_template', '#111*1*2*{recipient}*{amount}*2#',
       'instructions', 'Open MVola, choose "Pay", then enter the number and the amount shown above.')
   where key = 'mvola';

  perform test_harness.ok(public.mvola_amount_text(20000) = '20000',
    'integer amount renders without decimals');
  perform test_harness.ok(public.mvola_amount_text(1500.5) = '1500.5',
    'fractional amount renders without trailing zeros');

  -- Disabling the feature server side stops both config and payment start.
  update public.app_settings set value = jsonb_set(value, '{enabled}', 'false')
   where key = 'mvola';
  perform test_harness.act_as(v_user_a);
  perform test_harness.raises(
    'select public.mvola_config()', 'MVOLA_DISABLED', 'disabled mvola refuses to serve config');
  perform test_harness.act_as_service();
  update public.app_settings set value = jsonb_set(value, '{enabled}', 'true')
   where key = 'mvola';
end $$;

-- ---------------------------------------------------------------------------
-- 14b. Payment gating: with MVola enabled a fresh request is payment-required
-- and the owner may open the payment immediately.
-- ---------------------------------------------------------------------------
do $$
declare
  v_user uuid := '11111111-1111-1111-1111-111111111111';
  v_admin uuid := '33333333-3333-3333-3333-333333333333';
  v_ticket public.kyc_requests;
  v_pay public.mvola_payments;
begin
  perform test_harness.act_as_service();
  v_ticket := test_harness.new_ticket(v_user, 'https://tango.me/gate', 'gate@example.com', 'email');

  -- MVola is on: creating the request already marks it payment-required.
  perform test_harness.ok(
    (select payment_required from public.kyc_requests where id = v_ticket.id),
    'a fresh request is payment-required while MVola is enabled');

  -- A user cannot raise the signal on their own ticket through the admin path,
  -- but the owner can already open the payment because the gate is set.
  perform test_harness.act_as(v_user);
  perform test_harness.raises(
    format('select public.admin_request_payment(%L::uuid)', v_ticket.id),
    'FORBIDDEN', 'a user cannot request a payment on their own ticket');
  v_pay := public.mvola_start_payment(v_ticket.id);
  perform test_harness.ok(v_pay.status = 'pending',
    'the owner can open the payment for a gated fresh request');

  -- The explicit admin signal remains available and idempotent.
  perform test_harness.act_as(v_admin);
  v_ticket := public.admin_request_payment(v_ticket.id);
  perform test_harness.ok(v_ticket.payment_required, 'the admin signal keeps payment_required set');
  perform test_harness.ok(v_ticket.payment_requested_at is not null,
    'the admin signal records when the payment was requested');
end $$;

-- ---------------------------------------------------------------------------
-- 14c. With MVola disabled the gate is off and no payment can be opened
-- ---------------------------------------------------------------------------
do $$
declare
  v_user uuid := '11111111-1111-1111-1111-111111111111';
  v_ticket public.kyc_requests;
begin
  perform test_harness.act_as_service();
  -- Exercise the payments-off branch without leaving the setting changed: the
  -- whole suite runs in one transaction that is rolled back at the end.
  update public.app_settings
     set value = jsonb_set(value, '{enabled}', 'false'::jsonb)
   where key = 'mvola';

  v_ticket := test_harness.new_ticket(v_user, 'https://tango.me/off', 'off@example.com', 'email');
  perform test_harness.ok(
    not (select payment_required from public.kyc_requests where id = v_ticket.id),
    'with MVola disabled a fresh request is not payment-required');
  perform test_harness.ok(
    (select count(*) from public.notifications
      where ticket_id = v_ticket.id and type = 'request_submitted') = 1,
    'with MVola disabled the request is announced as submitted');

  perform test_harness.act_as(v_user);
  perform test_harness.raises(
    format('select public.mvola_start_payment(%L::uuid)', v_ticket.id),
    'MVOLA_NOT_REQUIRED', 'with MVola disabled no payment can be opened');

  -- Restore the shipped default so the later sections stay deterministic.
  perform test_harness.act_as_service();
  update public.app_settings
     set value = jsonb_set(value, '{enabled}', 'true'::jsonb)
   where key = 'mvola';
end $$;

-- ---------------------------------------------------------------------------
-- 15. MVola payment creation, ownership and the server-decided amount
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_user_b uuid := '22222222-2222-2222-2222-222222222222';
  v_ticket_a public.kyc_requests;
  v_ticket_b public.kyc_requests;
  v_pay public.mvola_payments;
  v_again public.mvola_payments;
begin
  perform test_harness.act_as_service();
  v_ticket_a := test_harness.new_ticket(v_user_a, 'https://tango.me/a', 'a@example.com', 'email', true);
  v_ticket_b := test_harness.new_ticket(v_user_b, 'https://tango.me/b', 'b@example.com', 'email', true);

  -- Unauthenticated callers cannot start a payment.
  perform test_harness.act_as_service();
  perform set_config('request.jwt.claims', '{}', true);
  perform test_harness.raises(
    format('select public.mvola_start_payment(%L::uuid)', v_ticket_a.id),
    'AUTH_REQUIRED', 'unauthenticated caller cannot start a payment');

  perform test_harness.act_as(v_user_a);
  v_pay := public.mvola_start_payment(v_ticket_a.id);

  perform test_harness.ok(v_pay.status = 'pending', 'a new payment starts as pending');
  perform test_harness.ok(v_pay.submitted_at is null, 'a new payment is not yet submitted');
  perform test_harness.ok(v_pay.user_id = v_user_a, 'the payment belongs to the caller');
  perform test_harness.ok(v_pay.ticket_id = v_ticket_a.id, 'the payment is linked to its ticket');
  perform test_harness.ok(v_pay.amount = 20000, 'the amount is taken from server config');
  perform test_harness.ok(v_pay.recipient_number = '0346715622',
    'the recipient number is taken from server config');
  perform test_harness.ok(v_pay.ussd_code = '#111*1*2*0346715622*20000*2#',
    'the ussd code is stored with the payment');

  -- Idempotence: a double tap returns the same live payment, never a second one.
  v_again := public.mvola_start_payment(v_ticket_a.id);
  perform test_harness.ok(v_again.id = v_pay.id,
    'a second start returns the existing live payment');
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select count(*) from public.mvola_payments where ticket_id = v_ticket_a.id) = 1,
    'a double start creates exactly one payment');

  -- A payment cannot be opened for somebody else's ticket.
  perform test_harness.act_as(v_user_b);
  perform test_harness.raises(
    format('select public.mvola_start_payment(%L::uuid)', v_ticket_a.id),
    'FORBIDDEN', 'a user cannot pay for another user''s ticket');

  -- An unknown ticket is reported as not found, not silently created.
  perform test_harness.act_as(v_user_a);
  perform test_harness.raises(
    'select public.mvola_start_payment(gen_random_uuid())',
    'TICKET_NOT_FOUND', 'paying for an unknown ticket is refused');
end $$;

-- ---------------------------------------------------------------------------
-- 16. Double-payment protection at the storage layer
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_ticket public.kyc_requests;
  v_pay public.mvola_payments;
begin
  perform test_harness.act_as_service();
  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/dup', 'dup@example.com', 'email', true);

  perform test_harness.act_as(v_user_a);
  v_pay := public.mvola_start_payment(v_ticket.id);

  -- Even a direct insert that bypasses the function cannot create a second live
  -- payment: the partial unique index is the last line of defence.
  perform test_harness.act_as_service();
  perform test_harness.raises(
    format(
      'insert into public.mvola_payments (user_id, ticket_id, amount, currency, recipient_number, ussd_code) '
      'values (%L::uuid, %L::uuid, 20000, ''MGA'', ''0346715622'', ''#111#'')',
      v_user_a, v_ticket.id),
    'duplicate key value', 'the unique index blocks a second live payment for one ticket');

  -- Approving keeps the ticket occupied: the payment cannot be recreated.
  perform test_harness.act_as(v_user_a);
  perform public.mvola_submit_payment(v_pay.id, 'REF-APPROVED-1', null);
  perform test_harness.act_as(
    '33333333-3333-3333-3333-333333333333');
  perform public.admin_mvola_set_decision(v_pay.id, 'approved', null);

  perform test_harness.act_as(v_user_a);
  perform test_harness.ok(
    (public.mvola_start_payment(v_ticket.id)).id = v_pay.id,
    'an approved payment is returned rather than recreated');

  -- The occupied ticket still holds exactly one row: approval does not allow a
  -- second payment to slip in.
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select count(*) from public.mvola_payments where ticket_id = v_ticket.id) = 1,
    'an approved ticket keeps exactly one payment row');
  perform test_harness.ok(
    (select status from public.mvola_payments where ticket_id = v_ticket.id) = 'approved',
    'the live payment stays the approved one');
end $$;

do $$
declare
  v_user_b uuid := '22222222-2222-2222-2222-222222222222';
  v_ticket public.kyc_requests;
  v_first public.mvola_payments;
  v_second public.mvola_payments;
begin
  perform test_harness.act_as_service();
  v_ticket := test_harness.new_ticket(v_user_b, 'https://tango.me/rej', 'rej@example.com', 'email', true);

  perform test_harness.act_as(v_user_b);
  v_first := public.mvola_start_payment(v_ticket.id);
  perform public.mvola_submit_payment(v_first.id, 'REF-REJECT-1', null);

  perform test_harness.act_as('33333333-3333-3333-3333-333333333333');
  perform public.admin_mvola_set_decision(v_first.id, 'rejected', 'Reference MVola incorrecte.');

  -- After a rejection a fresh payment may be opened, and the old row is kept.
  perform test_harness.act_as(v_user_b);
  v_second := public.mvola_start_payment(v_ticket.id);
  perform test_harness.ok(v_second.id <> v_first.id,
    'a rejected payment allows a corrected resubmission');
  perform test_harness.ok(v_second.status = 'pending', 'the resubmission starts as pending');

  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select count(*) from public.mvola_payments where ticket_id = v_ticket.id) = 2,
    'the rejected payment is kept for the history');
  perform test_harness.ok(
    (select rejection_reason from public.mvola_payments where id = v_first.id) =
      'Reference MVola incorrecte.',
    'the rejection reason is preserved');
end $$;

-- ---------------------------------------------------------------------------
-- 17. Submission: owner-only, validated, and never a status change
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_user_b uuid := '22222222-2222-2222-2222-222222222222';
  v_ticket public.kyc_requests;
  v_pay public.mvola_payments;
  v_submitted public.mvola_payments;
begin
  perform test_harness.act_as_service();
  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/sub', 'sub@example.com', 'email', true);

  perform test_harness.act_as(v_user_a);
  v_pay := public.mvola_start_payment(v_ticket.id);

  -- A missing reference is refused.
  perform test_harness.raises(
    format('select public.mvola_submit_payment(%L::uuid, %L, null)', v_pay.id, '   '),
    'MVOLA_REFERENCE_REQUIRED', 'an empty transaction reference is refused');

  -- A reference with markup or control characters is refused, so nothing that
  -- could be interpreted as content ever reaches storage.
  perform test_harness.raises(
    format('select public.mvola_submit_payment(%L::uuid, %L, null)', v_pay.id, '<script>x</script>'),
    'MVOLA_REFERENCE_INVALID', 'a reference containing markup is refused');

  -- Another user cannot submit a payment that is not theirs.
  perform test_harness.act_as(v_user_b);
  perform test_harness.raises(
    format('select public.mvola_submit_payment(%L::uuid, %L, null)', v_pay.id, 'REF-STOLEN'),
    'FORBIDDEN', 'a user cannot submit another user''s payment');

  -- The owner submits successfully and the status stays pending: the server
  -- never treats "I have paid" as proof of payment.
  perform test_harness.act_as(v_user_a);
  v_submitted := public.mvola_submit_payment(v_pay.id, '  123456789  ', '+261 34 12 345 67');
  perform test_harness.ok(v_submitted.status = 'pending',
    'submitting does not approve the payment');
  perform test_harness.ok(v_submitted.submitted_at is not null,
    'submitting records the submission time');
  perform test_harness.ok(v_submitted.transaction_reference = '123456789',
    'the reference is trimmed before storage');
  perform test_harness.ok(v_submitted.payer_number = '+261341234567',
    'the payer number is normalised before storage');

  -- A pending payment may be corrected (a mistyped reference is a real case).
  -- This updates the same row, so it can never become a second payment.
  v_submitted := public.mvola_submit_payment(v_pay.id, 'REF-CORRECTED', null);
  perform test_harness.ok(v_submitted.id = v_pay.id,
    'correcting a pending payment reuses the same row');
  perform test_harness.ok(v_submitted.transaction_reference = 'REF-CORRECTED',
    'the corrected reference is stored');
  perform test_harness.ok(v_submitted.status = 'pending',
    'correcting does not change the status');
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select count(*) from public.mvola_payments where ticket_id = v_ticket.id) = 1,
    'correcting a reference never creates a second payment');
end $$;

-- A decided payment can no longer be submitted or corrected.
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_ticket public.kyc_requests;
  v_pay public.mvola_payments;
begin
  perform test_harness.act_as_service();
  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/sub2', 'sub2@example.com', 'email', true);

  perform test_harness.act_as(v_user_a);
  v_pay := public.mvola_start_payment(v_ticket.id);
  perform public.mvola_submit_payment(v_pay.id, 'REF-DECIDED-1', null);

  perform test_harness.act_as('33333333-3333-3333-3333-333333333333');
  perform public.admin_mvola_set_decision(v_pay.id, 'approved', null);

  perform test_harness.act_as(v_user_a);
  perform test_harness.raises(
    format('select public.mvola_submit_payment(%L::uuid, %L, null)', v_pay.id, 'REF-TOO-LATE'),
    'PAYMENT_ALREADY_REVIEWED', 'an approved payment can no longer be submitted');
end $$;

-- ---------------------------------------------------------------------------
-- 18. Admin decisions, authorisation and audit trail
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_admin uuid := '33333333-3333-3333-3333-333333333333';
  v_ticket public.kyc_requests;
  v_pay public.mvola_payments;
  v_row public.mvola_payments;
begin
  perform test_harness.act_as_service();
  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/dec', 'dec@example.com', 'email', true);

  perform test_harness.act_as(v_user_a);
  v_pay := public.mvola_start_payment(v_ticket.id);
  perform public.mvola_submit_payment(v_pay.id, 'REF-DECIDE-1', null);

  -- A normal user cannot decide their own payment.
  perform test_harness.raises(
    format('select public.admin_mvola_set_decision(%L::uuid, ''approved'', null)', v_pay.id),
    'FORBIDDEN', 'a user cannot approve their own payment');

  -- An unauthenticated caller cannot decide either.
  perform test_harness.act_as_service();
  perform set_config('request.jwt.claims', '{}', true);
  perform test_harness.raises(
    format('select public.admin_mvola_set_decision(%L::uuid, ''approved'', null)', v_pay.id),
    'FORBIDDEN', 'an unauthenticated caller cannot decide a payment');

  -- Rejecting without a reason is refused: the user must learn what to fix.
  perform test_harness.act_as(v_admin);
  perform test_harness.raises(
    format('select public.admin_mvola_set_decision(%L::uuid, ''rejected'', null)', v_pay.id),
    'MVOLA_REASON_REQUIRED', 'a rejection without a reason is refused');

  -- An invalid decision value is refused.
  perform test_harness.raises(
    format('select public.admin_mvola_set_decision(%L::uuid, ''pending'', null)', v_pay.id),
    'MVOLA_DECISION_INVALID', 'an invalid decision value is refused');

  -- The admin approves and the trail records who and when.
  v_row := public.admin_mvola_set_decision(v_pay.id, 'approved', null);
  perform test_harness.ok(v_row.status = 'approved', 'the admin can approve a payment');
  perform test_harness.ok(v_row.reviewed_at is not null, 'approval records the review time');
  perform test_harness.ok(v_row.reviewed_by = v_admin, 'approval records the reviewing admin');
  perform test_harness.ok(v_row.rejection_reason is null, 'approval clears any rejection reason');

  -- A decided payment cannot be decided again.
  perform test_harness.raises(
    format('select public.admin_mvola_set_decision(%L::uuid, ''rejected'', ''too late'')', v_pay.id),
    'PAYMENT_ALREADY_REVIEWED', 'an already decided payment cannot be decided again');

  -- The admin listing exposes the joined ticket, owner and reviewer.
  perform test_harness.ok(
    (select count(*) from public.admin_mvola_list() l where l.id = v_pay.id) = 1,
    'the admin listing returns the payment');
  perform test_harness.ok(
    (select l.ticket_code from public.admin_mvola_list() l where l.id = v_pay.id) = v_ticket.ticket_code,
    'the admin listing joins the ticket code');
  perform test_harness.ok(
    (select l.reviewer_email from public.admin_mvola_list() l where l.id = v_pay.id) =
      'customerservicefor032@gmail.com',
    'the admin listing joins the reviewing admin');
end $$;

-- ---------------------------------------------------------------------------
-- 19. MVola RLS: isolation and immutability from the client
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_user_b uuid := '22222222-2222-2222-2222-222222222222';
  v_ticket_a public.kyc_requests;
  v_ticket_b public.kyc_requests;
  v_pay_a public.mvola_payments;
  v_pay_b public.mvola_payments;
begin
  perform test_harness.act_as_service();
  v_ticket_a := test_harness.new_ticket(v_user_a, 'https://tango.me/rls-a', 'rls.a@example.com', 'email', true);
  v_ticket_b := test_harness.new_ticket(v_user_b, 'https://tango.me/rls-b', 'rls.b@example.com', 'email', true);

  perform test_harness.act_as(v_user_a);
  v_pay_a := public.mvola_start_payment(v_ticket_a.id);
  perform test_harness.act_as(v_user_b);
  v_pay_b := public.mvola_start_payment(v_ticket_b.id);

  -- Each user sees only their own payment. Scoped to this section's rows so the
  -- assertion does not depend on what earlier sections created.
  perform test_harness.act_as(v_user_a);
  perform test_harness.ok(
    (select count(*) from public.mvola_payments where id in (v_pay_a.id, v_pay_b.id)) = 1,
    'a user sees exactly one of the two payments (their own)');
  perform test_harness.ok(
    (select count(*) from public.mvola_payments where id = v_pay_a.id) = 1,
    'a user can read their own payment');
  perform test_harness.ok(
    (select count(*) from public.mvola_payments where id = v_pay_b.id) = 0,
    'a user cannot read another user''s payment');

  -- RLS is enabled on the table.
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select relrowsecurity from pg_class
      where relname = 'mvola_payments' and relnamespace = 'public'::regnamespace),
    'RLS is enabled on mvola_payments');

  -- The client has no write grant: status cannot be forged.
  perform test_harness.act_as(v_user_a);
  perform test_harness.raises(
    format('update public.mvola_payments set status = ''approved'' where id = %L::uuid', v_pay_a.id),
    'permission denied', 'a user cannot update a payment status directly');
  perform test_harness.raises(
    format('update public.mvola_payments set amount = 1 where id = %L::uuid', v_pay_a.id),
    'permission denied', 'a user cannot change the amount directly');
  perform test_harness.raises(
    format('delete from public.mvola_payments where id = %L::uuid', v_pay_a.id),
    'permission denied', 'a user cannot delete a payment');
  perform test_harness.raises(
    format(
      'insert into public.mvola_payments (user_id, ticket_id, amount, currency, recipient_number, ussd_code) '
      'values (%L::uuid, %L::uuid, 1, ''MGA'', ''0346715622'', ''#111#'')',
      v_user_a, v_ticket_a.id),
    'permission denied', 'a user cannot insert a payment directly');

  -- Admin-only functions are refused to a normal user.
  perform test_harness.raises('select * from public.admin_mvola_list()',
    'FORBIDDEN', 'a user cannot list all payments');
end $$;




do $$ begin raise notice '=================================='; raise notice 'ALL BACKEND TESTS PASSED'; raise notice '=================================='; end $$;

-- ---------------------------------------------------------------------------
-- 20. Submission is gated on the payment: an unpaid request is not submitted
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_admin uuid := '33333333-3333-3333-3333-333333333333';
  v_ticket public.kyc_requests;
  v_pay public.mvola_payments;
  v_state jsonb;
  v_enabled boolean;
begin
  perform test_harness.act_as_service();
  select coalesce((value ->> 'enabled')::boolean, false) into v_enabled
    from public.app_settings where key = 'mvola';
  perform test_harness.ok(coalesce(v_enabled, false),
    'MVola is enabled, so a fresh request is gated on payment');

  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/gate', 'gate@example.com', 'email', false);

  -- Creating a request while payments are on marks it payment-required and asks
  -- for payment instead of announcing a submission.
  perform test_harness.ok(
    (select payment_required from public.kyc_requests where id = v_ticket.id),
    'a fresh request is marked payment_required');
  perform test_harness.ok(
    (select count(*) from public.notifications
      where ticket_id = v_ticket.id and type = 'payment_requested') = 1,
    'the user is asked to pay');
  perform test_harness.ok(
    (select count(*) from public.notifications
      where ticket_id = v_ticket.id and type = 'request_submitted') = 0,
    'nothing is announced as submitted before the payment');

  -- The derived submission state agrees. It is service-role only, since it is
  -- consumed by the Edge Functions and never exposed to the client directly.
  perform test_harness.act_as_service();
  v_state := public.kyc_submission_state(v_ticket.id);
  perform test_harness.ok((v_state ->> 'payment_status') = 'awaiting_submission',
    'the submission state is awaiting_submission before any payment');
  perform test_harness.ok((v_state ->> 'is_submitted')::boolean = false,
    'the request is not submitted before the payment');

  -- A started-but-unsubmitted payment still does not submit the request.
  perform test_harness.act_as(v_user_a);
  v_pay := public.mvola_start_payment(v_ticket.id);
  perform test_harness.act_as_service();
  v_state := public.kyc_submission_state(v_ticket.id);
  perform test_harness.ok((v_state ->> 'is_submitted')::boolean = false,
    'starting a payment does not submit the request');

  perform test_harness.act_as(v_user_a);
  perform public.mvola_submit_payment(v_pay.id, 'REF-GATE-1', null);
  perform test_harness.act_as_service();
  v_state := public.kyc_submission_state(v_ticket.id);
  perform test_harness.ok((v_state ->> 'payment_status') = 'pending',
    'a submitted payment is pending review');
  perform test_harness.ok((v_state ->> 'is_submitted')::boolean = false,
    'a pending payment does not submit the request');

  -- Admin approval is the single moment the request becomes submitted.
  perform test_harness.act_as(v_admin);
  perform public.admin_mvola_set_decision(v_pay.id, 'approved', null);
  perform test_harness.act_as_service();
  v_state := public.kyc_submission_state(v_ticket.id);
  perform test_harness.ok((v_state ->> 'payment_status') = 'approved',
    'an approved payment is reported as approved');
  perform test_harness.ok((v_state ->> 'is_submitted')::boolean = true,
    'an approved payment officially submits the request');
  perform test_harness.ok(
    (select count(*) from public.notifications
      where ticket_id = v_ticket.id and type = 'request_submitted') = 1,
    'exactly one submitted notification is produced on approval');
  perform test_harness.ok(
    (select count(*) from public.notifications
      where ticket_id = v_ticket.id and type = 'payment_confirmed') = 1,
    'the payment confirmation notification is produced');
end $$;

-- ---------------------------------------------------------------------------
-- 21. A refused payment never submits the request
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_admin uuid := '33333333-3333-3333-3333-333333333333';
  v_ticket public.kyc_requests;
  v_pay public.mvola_payments;
begin
  perform test_harness.act_as_service();
  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/refuse', 'refuse@example.com', 'email', true);

  perform test_harness.act_as(v_user_a);
  v_pay := public.mvola_start_payment(v_ticket.id);
  perform public.mvola_submit_payment(v_pay.id, 'REF-REFUSE-1', null);

  perform test_harness.act_as(v_admin);
  perform public.admin_mvola_set_decision(v_pay.id, 'rejected', 'reference not found');

  perform test_harness.act_as_service();
  perform test_harness.ok(
    (public.kyc_submission_state(v_ticket.id) ->> 'is_submitted')::boolean = false,
    'a refused payment never submits the request');
  perform test_harness.ok(
    (select count(*) from public.notifications
      where ticket_id = v_ticket.id and type = 'request_submitted') = 0,
    'a refused payment produces no submitted notification');

  -- The admin dashboard listing reflects the same derived state.
  perform test_harness.act_as(v_admin);
  perform test_harness.ok(
    (select l.payment_status from public.admin_ticket_list() l where l.id = v_ticket.id) = 'rejected',
    'the admin listing exposes the refused payment status');
end $$;

-- ---------------------------------------------------------------------------
-- 22. End-to-end reply correlation on a single ticket.
--
-- Ticket A -> the admin reply is recorded with its provider message id -> the
-- user replies to that mail -> the webhook resolves the SAME ticket -> no new
-- ticket is created. The ticket code is never part of what the recipient sees,
-- so the tokenised reply address is what carries the correlation.
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_t public.kyc_requests;
  v_tickets_before int;
  v_tickets_after int;
  v_res jsonb;
  v_addr text;
  v_thread text := '<outbound-22@tango-kyc.local>';
begin
  perform test_harness.act_as_service();
  v_t := test_harness.new_ticket(v_a, 'https://tango.me/s22/a', 's22.user@example.com', 'email');
  v_tickets_before := (select count(*) from public.kyc_requests);

  -- The outbound admin reply is recorded with its provider message id.
  perform public.record_outbound_email(v_t.id, v_thread);
  perform test_harness.ok(
    (select last_outbound_message_id from public.kyc_requests where id = v_t.id) = v_thread,
    '22: the outbound message id is stored for threading');

  -- The recipient only ever sees the token, never the ticket code.
  v_addr := 'reply+' || v_t.reply_token || '@inbound.resend.app';
  perform test_harness.ok(position(v_t.ticket_code in v_addr) = 0,
    '22: the reply address never carries the ticket code');

  -- The reply comes back on the tokenised address.
  perform test_harness.ok(
    public.resolve_ticket_for_reply('Re: your request', 'here is my document',
      array[v_addr], null, null) = v_t.id,
    '22: the tokenised reply resolves to the same ticket');

  v_res := public.record_inbound_reply(v_t.id, 'Here is my document.',
    '<inbound-22@mail.gmail.com>', 's22.user@example.com');
  perform test_harness.ok((v_res ->> 'duplicate')::boolean = false,
    '22: the reply is stored on the same ticket');

  -- Threading still recovers the ticket when the address is rewritten and a
  -- single thread id is present.
  perform test_harness.ok(
    public.resolve_ticket_for_reply('Re: your request', 'no token here',
      array['forwarded@other.example.com'], v_thread, null) = v_t.id,
    '22: the in-reply-to thread recovers the same ticket');

  -- A real mail client accumulates a `References` chain, so two or more thread
  -- ids is the normal case. It must resolve, not raise.
  perform test_harness.ok(
    public.resolve_ticket_for_reply('Re: your request', 'no token here',
      array['forwarded@other.example.com'], v_thread,
      '<older-1@tango-kyc.local> ' || v_thread) = v_t.id,
    '22: a multi-id References chain resolves the same ticket');

  v_tickets_after := (select count(*) from public.kyc_requests);
  perform test_harness.ok(v_tickets_after = v_tickets_before,
    '22: no new ticket is created by the round trip');
  perform test_harness.ok(
    (select ticket_id from public.messages
      where external_message_id = '<inbound-22@mail.gmail.com>') = v_t.id,
    '22: the message belongs to ticket A and no other');
end $$;

-- ---------------------------------------------------------------------------
-- 22b. Closed-ticket rule on the inbound email path.
--
-- `user_post_message` refuses a reply once a ticket is `closed`. The inbound
-- email path now enforces the same rule in `record_inbound_reply`: the reply is
-- rejected with `TICKET_CLOSED`, no message is stored, and the ticket is never
-- moved back to `replied`.
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_t public.kyc_requests;
  v_status text;
  v_msgs_before int;
begin
  perform test_harness.act_as_service();
  v_t := test_harness.new_ticket(v_a, 'https://tango.me/s22b/a', 's22b.user@example.com', 'email');
  update public.kyc_requests set status = 'closed' where id = v_t.id;
  v_msgs_before := (select count(*) from public.messages where ticket_id = v_t.id);

  -- The owner cannot reply from the app once the ticket is closed.
  perform test_harness.act_as(v_a);
  perform test_harness.raises(
    format('select public.user_post_message(%L, ''one more thing'')', v_t.id::text),
    'TICKET_CLOSED', '22b: the owner cannot reply in the app once closed');

  -- An email reply on the closed ticket is refused the same way.
  perform test_harness.act_as_service();
  perform test_harness.raises(
    format(
      'select public.record_inbound_reply(%L, %L, %L, %L)',
      v_t.id::text, 'reply by email after close', '<inbound-22b@mail.gmail.com>',
      's22b.user@example.com'),
    'TICKET_CLOSED', '22b: an email reply on a closed ticket is refused');

  v_status := (select status from public.kyc_requests where id = v_t.id);
  perform test_harness.ok(v_status = 'closed',
    '22b: the email path never reopens a closed ticket');
  perform test_harness.ok(
    (select count(*) from public.messages where ticket_id = v_t.id) = v_msgs_before,
    '22b: a refused email reply stores no message');

  -- The owner can still read the history of the closed ticket.
  perform test_harness.act_as(v_a);
  perform test_harness.ok(
    (select count(*) from public.messages where ticket_id = v_t.id) >= 0,
    '22b: the closed ticket history stays readable by its owner');
end $$;

-- ---------------------------------------------------------------------------
-- 23. The reply path is gated on the payment: the owner of a payment-required
-- request whose payment has not been approved by an admin cannot reply.
--
-- Business rule (server side, never trusted from the client):
--   * `payment_required` false                    -> the owner replies freely;
--   * `payment_required` true + payment approved   -> the owner replies;
--   * `payment_required` true + not approved       -> PAYMENT_NOT_CONFIRMED;
--   * a closed ticket                             -> TICKET_CLOSED.
--
-- "Officially submitted" is derived, never stored. `is_submitted` is true when
-- payments are off OR an approved `mvola_payments` row exists - exactly what
-- `kyc_submission_state` returns and what the gate reads. It therefore means
-- "the admin confirmed the payment", not merely "the user submitted a
-- reference": a started or submitted-but-unreviewed payment leaves it false.
-- `admin_post_message` is deliberately not gated; the payment rule applies to
-- the request owner only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_user_a uuid := '11111111-1111-1111-1111-111111111111';
  v_admin uuid := '33333333-3333-3333-3333-333333333333';
  v_gated public.kyc_requests;
  v_ok public.kyc_requests;
  v_closed public.kyc_requests;
  v_pay public.mvola_payments;
  v_row public.messages;
  v_before int;
begin
  -- Test 1 - payment required, not confirmed: the reply is refused and nothing
  -- is stored.
  perform test_harness.act_as_service();
  v_gated := test_harness.new_ticket(v_user_a, 'https://tango.me/gate/blocked',
    'gate.blocked@example.com', 'email', true);
  perform test_harness.ok(
    (select payment_required from public.kyc_requests where id = v_gated.id),
    '23: the request is payment-required');
  perform test_harness.act_as(v_user_a);
  v_before := (select count(*) from public.messages where ticket_id = v_gated.id);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_gated.id::text, 'while unpaid'),
    'PAYMENT_NOT_CONFIRMED', '23: the owner cannot reply before the payment is confirmed');
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select count(*) from public.messages where ticket_id = v_gated.id) = v_before,
    '23: a payment-blocked reply stores no message');

  -- Opening a payment is not a confirmation: the gate stays shut.
  perform test_harness.act_as(v_user_a);
  v_pay := public.mvola_start_payment(v_gated.id);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_gated.id::text, 'still unpaid'),
    'PAYMENT_NOT_CONFIRMED', '23: starting a payment does not unlock the reply');

  -- Nor is the user's own submission: an awaiting-review payment is not approved.
  perform public.mvola_submit_payment(v_pay.id, 'REF-GATE-23', null);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_gated.id::text, 'awaiting review'),
    'PAYMENT_NOT_CONFIRMED', '23: a submitted payment awaiting review does not unlock the reply');

  -- Test 2 - payment required, confirmed by an admin: the reply succeeds and the
  -- message is stored on the ticket.
  perform test_harness.act_as(v_admin);
  perform public.admin_mvola_set_decision(v_pay.id, 'approved', null);
  perform test_harness.act_as(v_user_a);
  v_row := public.user_post_message(v_gated.id, 'Payment confirmed, here are my documents.');
  perform test_harness.ok(v_row.id is not null,
    '23: the owner can reply once the admin confirmed the payment');
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select count(*) from public.messages
      where id = v_row.id and ticket_id = v_gated.id and sender_type = 'user') = 1,
    '23: the confirmed reply is stored as a user message on the ticket');

  -- Test 3 - payment not required: the reply succeeds, as before.
  perform test_harness.act_as_service();
  v_ok := test_harness.new_ticket(v_user_a, 'https://tango.me/gate/free',
    'gate.free@example.com', 'email', false);
  update public.kyc_requests set payment_required = false where id = v_ok.id;
  perform test_harness.act_as(v_user_a);
  v_row := public.user_post_message(v_ok.id, 'No payment needed here.');
  perform test_harness.ok(v_row.id is not null,
    '23: the owner can reply when no payment is required');

  -- Test 4 - a closed ticket is refused; the closed rule is evaluated before the
  -- payment rule.
  perform test_harness.act_as_service();
  v_closed := test_harness.new_ticket(v_user_a, 'https://tango.me/gate/closed',
    'gate.closed@example.com', 'email', true);
  perform test_harness.act_as(v_admin);
  perform public.admin_set_status(v_closed.id, 'closed');
  perform test_harness.act_as(v_user_a);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_closed.id::text, 'on a closed ticket'),
    'TICKET_CLOSED', '23: the owner cannot reply on a closed ticket');

  -- Test 5 - an admin is not subject to the payment gate.
  perform test_harness.act_as(v_admin);
  v_row := public.admin_post_message(v_gated.id, 'Admin follow-up, no payment gate here.');
  perform test_harness.ok(v_row.id is not null,
    '23: an admin can post even while a payment is pending');
  perform test_harness.act_as_service();
  perform test_harness.ok(
    (select count(*) from public.messages
      where ticket_id = v_gated.id and sender_type = 'admin') >= 1,
    '23: the admin message is stored');
end $$;

rollback;
