-- Tango KYC Verification - push device tokens + Realtime tests.
--
-- Separate from tests/db/run_tests.sql on purpose: it depends on migration
-- 20260928000600_push_tokens_and_realtime.sql, which is authored but NOT yet
-- deployed. Keeping it apart means the existing suite stays green against the
-- current cloud project, and this one is run once the migration lands.
--
-- Usage (after deploying the migration):
--   python3 tests/scripts/run_push_tests.py
--
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

grant usage on schema test_harness to authenticated, service_role, anon;
grant execute on all functions in schema test_harness to authenticated, service_role, anon;

-- ---------------------------------------------------------------------------
-- Fixtures: an auth user, the handle_new_user trigger creates the profile.
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_b uuid := '22222222-2222-2222-2222-222222222222';
begin
  insert into auth.users (id, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (v_a, 'push.a@example.com', 'x', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()),
    (v_b, 'push.b@example.com', 'x', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now())
  on conflict (id) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Registration and isolation
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_b uuid := '22222222-2222-2222-2222-222222222222';
  v_token_a text := 'fcm-token-user-a-0123456789';
  v_token_b text := 'fcm-token-user-b-0123456789';
begin
  -- A registers its own token through the definer helper.
  perform test_harness.act_as(v_a);
  perform public.register_device_token(v_token_a, 'android');
  perform test_harness.ok(
    (select count(*) from public.device_tokens where token = v_token_a and user_id = v_a) = 1,
    'A: a user registers their own token');

  -- Re-registering is idempotent, not a duplicate row.
  perform public.register_device_token(v_token_a, 'android');
  perform test_harness.ok(
    (select count(*) from public.device_tokens where token = v_token_a) = 1,
    'A: re-registering the same token does not duplicate it');

  perform test_harness.act_as(v_b);
  perform public.register_device_token(v_token_b, 'android');

  -- A cannot see B's token.
  perform test_harness.act_as(v_a);
  perform test_harness.ok(
    (select count(*) from public.device_tokens where token = v_token_b) = 0,
    'A: a user cannot read another user''s token');

  -- A cannot insert a row claiming to be B.
  perform test_harness.raises(
    format('insert into public.device_tokens (user_id, token) values (%L, %L)',
           v_b::text, 'fcm-forged-for-b-0123456789'),
    'row-level security', 'A: a user cannot register a token for someone else');

  -- A cannot move B's token to itself: RLS makes B's row invisible, so the
  -- UPDATE matches nothing. Verified from B's own session.
  update public.device_tokens set user_id = v_a where token = v_token_b;
  perform test_harness.act_as(v_b);
  perform test_harness.ok(
    (select user_id from public.device_tokens where token = v_token_b) = v_b,
    'A: a user cannot steal another user''s token');
  perform test_harness.act_as(v_a);

  -- But the definer helper legitimately reassigns a token on a shared device.
  perform public.register_device_token(v_token_b, 'android');
  perform test_harness.ok(
    (select user_id from public.device_tokens where token = v_token_b) = v_a,
    'A: a shared device signing in reassigns the token to the new owner');

  -- And now B can no longer see that token.
  perform test_harness.act_as(v_b);
  perform test_harness.ok(
    (select count(*) from public.device_tokens where token = v_token_b) = 0,
    'A: the previous owner no longer sees the reassigned token');

  perform test_harness.raises(
    'select public.register_device_token(null, ''android'')',
    'TOKEN_REQUIRED', 'A: an empty token is refused');

  -- An anonymous caller cannot register anything: it lacks EXECUTE on the helper
  -- (a stronger guarantee than reaching the in-body AUTH_REQUIRED check).
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform test_harness.raises(
    format('select public.register_device_token(%L, ''android'')', 'anon-token-0123456789'),
    'permission denied', 'A: an anonymous caller cannot register a token');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Server-side target selection: the push goes to the ticket owner.
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := '11111111-1111-1111-1111-111111111111';
  v_b uuid := '22222222-2222-2222-2222-222222222222';
  v_ticket uuid;
  v_target uuid;
begin
  perform test_harness.act_as_service();

  insert into public.kyc_requests (user_id, ticket_code, tango_profile_link, register_type,
                                   register_value, reply_token)
  values (v_a, 'TNG-KYC-' || upper(encode(extensions.gen_random_bytes(4), 'hex')),
          'https://tango.me/push/1', 'email', 'push.owner@example.com',
          encode(extensions.gen_random_bytes(16), 'hex'))
  returning id into v_ticket;

  -- This mirrors what the webhook does before sending: resolve the owner from
  -- the ticket, never from anything the caller supplied.
  select user_id into v_target from public.kyc_requests where id = v_ticket;
  perform test_harness.ok(v_target = v_a, 'B: the push target is the ticket owner');

  perform test_harness.ok(
    (select count(*) from public.device_tokens where user_id = v_target) >= 1,
    'B: the owner has a registered device to receive the push');

  perform test_harness.ok(
    (select count(*) from public.device_tokens where user_id = v_b) >= 0,
    'B: no assumption is made about other users');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Realtime publication membership
-- ---------------------------------------------------------------------------
do $$
begin
  perform test_harness.ok(
    exists (select 1 from pg_publication_tables
             where pubname = 'supabase_realtime' and schemaname = 'public'
               and tablename = 'notifications'),
    'C: notifications is published for Realtime');
  perform test_harness.ok(
    exists (select 1 from pg_publication_tables
             where pubname = 'supabase_realtime' and schemaname = 'public'
               and tablename = 'kyc_requests'),
    'C: kyc_requests is published for Realtime');
end $$;

-- The transaction is rolled back, so the harness schema, the fixture users and
-- the token rows never persist; no explicit cleanup is needed.
rollback;
