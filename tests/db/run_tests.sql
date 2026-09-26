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
-- subject is something other than ticket creation.
create or replace function test_harness.new_ticket(
  p_user uuid, p_link text, p_value text, p_type public.register_type
)
returns public.kyc_requests
language plpgsql
as $$
declare
  v_row public.kyc_requests;
begin
  insert into public.kyc_requests (user_id, ticket_code, tango_profile_link, register_type,
                                   register_value, reply_token)
  values (p_user, 'TNG-KYC-' || upper(encode(extensions.gen_random_bytes(4), 'hex')),
          p_link, p_type, p_value, encode(extensions.gen_random_bytes(16), 'hex'))
  returning * into v_row;
  return v_row;
end;
$$;
grant execute on function test_harness.new_ticket(uuid, text, text, public.register_type)
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
      or email in ('user.a@example.com', 'user.b@example.com', 'rasonjonathan6@gmail.com');

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
     'rasonjonathan6@gmail.com', crypt('Password123!', gen_salt('bf')), now(),
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
    '<admin-reply-1@mail.gmail.com>', 'rasonjonathan6@gmail.com');
  perform test_harness.ok((v_res ->> 'duplicate')::boolean = false, 'first inbound reply stored');

  v_res2 := public.record_inbound_reply(v_t.id, E'Hello,\n\nYour verification request has been reviewed.',
    '<admin-reply-1@mail.gmail.com>', 'rasonjonathan6@gmail.com');
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
  v_t public.kyc_requests;
  v_id uuid;
begin
  perform test_harness.act_as_service();
  v_id := public.record_unmatched_reply('resend', 'evt_unmatched',
    'rasonjonathan6@gmail.com', 'reply@inbound.resend.app', 'Random', 'body', 'no_matching_ticket');
  perform test_harness.ok(v_id is not null, 'unmatched reply recorded');

  perform test_harness.act_as(v_a);
  perform test_harness.ok(
    (select count(*) from public.unmatched_replies) = 0,
    'unmatched replies are invisible to users');
  perform test_harness.raises(
    format('select public.admin_resolve_unmatched_reply(%L, %L)', v_id::text, gen_random_uuid()::text),
    'FORBIDDEN', 'non-admin cannot resolve a quarantined reply');

  select id into v_t from public.kyc_requests where user_id = v_a limit 1;
  perform public.user_post_message(v_t.id, 'Here are my documents.');
  perform test_harness.ok(
    (select count(*) from public.messages where ticket_id = v_t.id and sender_type = 'user') > 1,
    'user can post a message on their own ticket');

  perform test_harness.act_as(v_b);
  perform test_harness.raises(
    format('select public.user_post_message(%L, %L)', v_t.id::text, 'trespassing'),
    'FORBIDDEN', 'user cannot post on another user''s ticket');
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
    'rasonjonathan6@gmail.com', 'reply@inbound.resend.app', 'Re: KYC',
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
-- 13. Settings-driven configuration
-- ---------------------------------------------------------------------------
do $$
begin
  perform test_harness.act_as_service();
  perform test_harness.ok(public.setting_text('admin_email') = 'rasonjonathan6@gmail.com',
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
  v_ticket_a := test_harness.new_ticket(v_user_a, 'https://tango.me/a', 'a@example.com', 'email');
  v_ticket_b := test_harness.new_ticket(v_user_b, 'https://tango.me/b', 'b@example.com', 'email');

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
  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/dup', 'dup@example.com', 'email');

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
  v_ticket := test_harness.new_ticket(v_user_b, 'https://tango.me/rej', 'rej@example.com', 'email');

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
  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/sub', 'sub@example.com', 'email');

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
  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/sub2', 'sub2@example.com', 'email');

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
  v_ticket := test_harness.new_ticket(v_user_a, 'https://tango.me/dec', 'dec@example.com', 'email');

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
      'rasonjonathan6@gmail.com',
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
  v_ticket_a := test_harness.new_ticket(v_user_a, 'https://tango.me/rls-a', 'rls.a@example.com', 'email');
  v_ticket_b := test_harness.new_ticket(v_user_b, 'https://tango.me/rls-b', 'rls.b@example.com', 'email');

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

rollback;
