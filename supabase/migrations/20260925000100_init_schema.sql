-- Tango KYC Verification - core schema, roles, RLS and server-side business logic.
-- All privileged logic lives here so the Flutter client can never mutate
-- ownership, status or role columns.

create extension if not exists "pgcrypto" with schema extensions;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.app_role as enum ('user', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.register_type as enum ('email', 'phone');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.kyc_status as enum ('pending', 'in_review', 'replied', 'closed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.message_sender as enum ('user', 'admin', 'system');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Utility: keep updated_at fresh
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  display_name text,
  avatar_url text,
  role public.app_role not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- is_admin() is SECURITY DEFINER so it can be used inside RLS policies without
-- recursing into profiles' own policies.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select p.role = 'admin' from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- app_settings - server-side tunable configuration (anti-spam, addresses)
-- ---------------------------------------------------------------------------
create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

insert into public.app_settings (key, value) values
  ('rate_limit', '{"min_seconds_between_requests": 300, "max_requests_per_day": 5, "duplicate_window_hours": 24}'::jsonb),
  ('admin_email', '"customerservicefor032@gmail.com"'::jsonb),
  ('inbound_reply_domain', '"inbound.resend.app"'::jsonb)
on conflict (key) do nothing;

create or replace function public.setting_text(p_key text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select nullif(trim(both '"' from (value)::text), '') from public.app_settings where key = p_key;
$$;

create or replace function public.setting_int(p_key text, p_field text, p_default int)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((value ->> p_field)::int, p_default) from public.app_settings where key = p_key;
$$;

revoke all on function public.setting_text(text) from public;
revoke all on function public.setting_int(text, text, int) from public;
grant execute on function public.setting_text(text) to service_role;
grant execute on function public.setting_int(text, text, int) to service_role;

-- ---------------------------------------------------------------------------
-- kyc_requests
-- ---------------------------------------------------------------------------
create table if not exists public.kyc_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  ticket_code text not null unique,
  tango_profile_link text not null,
  register_type public.register_type not null,
  register_value text not null,
  status public.kyc_status not null default 'pending',
  -- Opaque token used as an email routing fallback: replies sent to
  -- reply+<token>@<inbound domain> are matched without relying on the ticket
  -- code surviving in the message body.
  reply_token text not null unique,
  email_thread_id text,
  last_outbound_message_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_reply_at timestamptz,
  constraint kyc_requests_tango_profile_link_format
    check (tango_profile_link ~* '^https?://[^\s]+$'),
  constraint kyc_requests_register_value_len
    check (char_length(register_value) between 3 and 320),
  constraint kyc_requests_ticket_code_format
    check (ticket_code ~ '^TNG-KYC-[0-9A-F]{8}$')
);

create index if not exists kyc_requests_user_id_created_at_idx
  on public.kyc_requests (user_id, created_at desc);
create index if not exists kyc_requests_status_created_at_idx
  on public.kyc_requests (status, created_at desc);
create index if not exists kyc_requests_reply_token_idx
  on public.kyc_requests (reply_token);
create index if not exists kyc_requests_register_value_idx
  on public.kyc_requests (register_value);

drop trigger if exists kyc_requests_touch_updated_at on public.kyc_requests;
create trigger kyc_requests_touch_updated_at
  before update on public.kyc_requests
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.kyc_requests (id) on delete cascade,
  sender_type public.message_sender not null,
  body text not null,
  external_message_id text,
  created_at timestamptz not null default now(),
  constraint messages_body_len check (char_length(body) between 1 and 20000)
);

-- Idempotency: a given provider message can only ever be stored once.
create unique index if not exists messages_external_message_id_key
  on public.messages (external_message_id)
  where external_message_id is not null;

create index if not exists messages_ticket_id_created_at_idx
  on public.messages (ticket_id, created_at);

-- ---------------------------------------------------------------------------
-- email_events - raw provider event log (idempotent ingestion)
-- ---------------------------------------------------------------------------
create table if not exists public.email_events (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid references public.kyc_requests (id) on delete set null,
  provider text not null,
  external_id text not null,
  event_type text not null,
  payload_hash text,
  created_at timestamptz not null default now()
);

create unique index if not exists email_events_provider_external_type_key
  on public.email_events (provider, external_id, event_type);

-- ---------------------------------------------------------------------------
-- unmatched_replies - admin-only quarantine for replies we cannot attribute
-- ---------------------------------------------------------------------------
create table if not exists public.unmatched_replies (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  external_id text not null,
  from_email text,
  to_email text,
  subject text,
  body_excerpt text,
  reason text not null,
  resolved_ticket_id uuid references public.kyc_requests (id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index if not exists unmatched_replies_provider_external_key
  on public.unmatched_replies (provider, external_id);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.kyc_requests enable row level security;
alter table public.messages enable row level security;
alter table public.email_events enable row level security;
alter table public.unmatched_replies enable row level security;
alter table public.app_settings enable row level security;

-- profiles -------------------------------------------------------------------
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Column-level privileges keep role/email/id immutable from the client even
-- though the row itself is updatable.
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, avatar_url, updated_at) on public.profiles to authenticated;

-- kyc_requests ---------------------------------------------------------------
drop policy if exists kyc_requests_select_own on public.kyc_requests;
create policy kyc_requests_select_own on public.kyc_requests
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- No insert/update/delete policy for authenticated: tickets are created and
-- mutated exclusively by the Edge Function running as service_role.
revoke all on public.kyc_requests from anon, authenticated;
grant select on public.kyc_requests to authenticated;

-- messages -------------------------------------------------------------------
drop policy if exists messages_select_own on public.messages;
create policy messages_select_own on public.messages
  for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.kyc_requests r
      where r.id = messages.ticket_id and r.user_id = auth.uid()
    )
  );

revoke all on public.messages from anon, authenticated;
grant select on public.messages to authenticated;

-- email_events ---------------------------------------------------------------
drop policy if exists email_events_admin_only on public.email_events;
create policy email_events_admin_only on public.email_events
  for select to authenticated
  using (public.is_admin());

revoke all on public.email_events from anon, authenticated;
grant select on public.email_events to authenticated;

-- unmatched_replies ----------------------------------------------------------
drop policy if exists unmatched_replies_admin_only on public.unmatched_replies;
create policy unmatched_replies_admin_only on public.unmatched_replies
  for select to authenticated
  using (public.is_admin());

revoke all on public.unmatched_replies from anon, authenticated;
grant select on public.unmatched_replies to authenticated;

-- app_settings ---------------------------------------------------------------
drop policy if exists app_settings_admin_only on public.app_settings;
create policy app_settings_admin_only on public.app_settings
  for select to authenticated
  using (public.is_admin());

revoke all on public.app_settings from anon, authenticated;
grant select on public.app_settings to authenticated;

-- ---------------------------------------------------------------------------
-- Profile bootstrap for new auth users
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name, avatar_url, role)
  values (
    new.id,
    new.email,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'name', ''),
      split_part(coalesce(new.email, ''), '@', 1)
    ),
    nullif(new.raw_user_meta_data ->> 'avatar_url', ''),
    case
      when coalesce(new.raw_app_meta_data ->> 'role', '') = 'admin' then 'admin'::public.app_role
      else 'user'::public.app_role
    end
  )
  on conflict (id) do update
    set email = excluded.email,
        display_name = coalesce(public.profiles.display_name, excluded.display_name),
        avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url),
        updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep profile role in sync when an operator promotes a user through the
-- Supabase admin API (raw_app_meta_data is server-controlled).
create or replace function public.handle_user_role_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.raw_app_meta_data ->> 'role', '') = 'admin' then
    update public.profiles set role = 'admin' where id = new.id and role <> 'admin';
  elsif coalesce(old.raw_app_meta_data ->> 'role', '') = 'admin' then
    update public.profiles set role = 'user' where id = new.id and role <> 'user';
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_role_changed on auth.users;
create trigger on_auth_user_role_changed
  after update of raw_app_meta_data on auth.users
  for each row execute function public.handle_user_role_change();

-- ---------------------------------------------------------------------------
-- Server-side normalisation helpers
-- ---------------------------------------------------------------------------
create or replace function public.normalize_register_value(p_value text)
returns text
language plpgsql
immutable
as $$
declare
  v text := trim(coalesce(p_value, ''));
begin
  if v = '' then
    return null;
  end if;
  if position('@' in v) > 0 then
    return lower(v);
  end if;
  -- Phone: keep an optional leading + and digits only.
  v := regexp_replace(v, '[^0-9+]', '', 'g');
  if left(v, 1) = '+' then
    v := '+' || regexp_replace(substr(v, 2), '[^0-9]', '', 'g');
  else
    v := regexp_replace(v, '[^0-9]', '', 'g');
  end if;
  return nullif(v, '');
end;
$$;

create or replace function public.detect_register_type(p_value text)
returns public.register_type
language plpgsql
immutable
as $$
declare
  v text := trim(coalesce(p_value, ''));
begin
  if position('@' in v) > 0 then
    return 'email'::public.register_type;
  end if;
  if regexp_replace(v, '[^0-9]', '', 'g') <> '' then
    return 'phone'::public.register_type;
  end if;
  return null;
end;
$$;

revoke all on function public.normalize_register_value(text) from public;
revoke all on function public.detect_register_type(text) from public;

-- ---------------------------------------------------------------------------
-- create_kyc_request - atomic, validated, rate limited ticket creation.
-- Callable by service_role only (i.e. from the Edge Function).
-- ---------------------------------------------------------------------------
create or replace function public.create_kyc_request(
  p_user_id uuid,
  p_tango_profile_link text,
  p_register_value text
)
returns public.kyc_requests
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_link text := trim(coalesce(p_tango_profile_link, ''));
  v_type public.register_type;
  v_value text;
  v_min_seconds int;
  v_max_per_day int;
  v_dup_hours int;
  v_last_created timestamptz;
  v_today_count int;
  v_duplicate public.kyc_requests;
  v_code text;
  v_token text;
  v_row public.kyc_requests;
  v_attempt int := 0;
begin
  if p_user_id is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;

  -- Serialise concurrent submissions from the same user.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 42));

  if v_link = '' then
    raise exception 'PROFILE_LINK_REQUIRED' using errcode = '22023';
  end if;
  if char_length(v_link) > 2048 then
    raise exception 'PROFILE_LINK_TOO_LONG' using errcode = '22023';
  end if;
  if v_link !~* '^https?://[^\s/]+\.[^\s/]+' then
    raise exception 'PROFILE_LINK_INVALID' using errcode = '22023';
  end if;

  v_type := public.detect_register_type(p_register_value);
  v_value := public.normalize_register_value(p_register_value);
  if v_type is null or v_value is null then
    raise exception 'REGISTER_REQUIRED' using errcode = '22023';
  end if;
  if v_type = 'email' and v_value !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then
    raise exception 'REGISTER_EMAIL_INVALID' using errcode = '22023';
  end if;
  if v_type = 'phone' then
    if char_length(regexp_replace(v_value, '[^0-9]', '', 'g')) < 7
       or char_length(regexp_replace(v_value, '[^0-9]', '', 'g')) > 15 then
      raise exception 'REGISTER_PHONE_INVALID' using errcode = '22023';
    end if;
  end if;

  v_min_seconds := coalesce(public.setting_int('rate_limit', 'min_seconds_between_requests', 300), 300);
  v_max_per_day := coalesce(public.setting_int('rate_limit', 'max_requests_per_day', 5), 5);
  v_dup_hours := coalesce(public.setting_int('rate_limit', 'duplicate_window_hours', 24), 24);

  -- An identical re-submission is deduplicated first: it is the same intent,
  -- not an extra request, so it must not consume the caller's rate budget.
  select * into v_duplicate
    from public.kyc_requests
   where user_id = p_user_id
     and tango_profile_link = v_link
     and register_value = v_value
     and status <> 'closed'
     and created_at > now() - make_interval(hours => v_dup_hours)
   order by created_at desc
   limit 1;

  if found then
    return v_duplicate;
  end if;

  select max(created_at) into v_last_created
    from public.kyc_requests where user_id = p_user_id;

  if v_last_created is not null
     and v_last_created > now() - make_interval(secs => v_min_seconds) then
    raise exception 'RATE_LIMITED' using errcode = 'P0001';
  end if;

  select count(*) into v_today_count
    from public.kyc_requests
   where user_id = p_user_id and created_at > now() - interval '24 hours';

  if v_today_count >= v_max_per_day then
    raise exception 'RATE_LIMITED_DAILY' using errcode = 'P0001';
  end if;

  loop
    v_attempt := v_attempt + 1;
    v_code := 'TNG-KYC-' || upper(encode(extensions.gen_random_bytes(4), 'hex'));
    v_token := encode(extensions.gen_random_bytes(16), 'hex');
    begin
      insert into public.kyc_requests (
        user_id, ticket_code, tango_profile_link, register_type, register_value, reply_token
      ) values (
        p_user_id, v_code, v_link, v_type, v_value, v_token
      )
      returning * into v_row;
      exit;
    exception when unique_violation then
      if v_attempt >= 5 then
        raise;
      end if;
    end;
  end loop;

  insert into public.messages (ticket_id, sender_type, body)
  values (
    v_row.id,
    'user',
    'Manual KYC verification request submitted.' || chr(10) ||
    'Tango profile link: ' || v_link || chr(10) ||
    case when v_type = 'email'
      then 'Register email: ' || v_value
      else 'Register number: ' || v_value
    end
  );

  return v_row;
end;
$$;

revoke all on function public.create_kyc_request(uuid, text, text) from public, anon, authenticated;
grant execute on function public.create_kyc_request(uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Admin statistics (admin only)
-- ---------------------------------------------------------------------------
create or replace function public.admin_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'total', count(*),
    'pending', count(*) filter (where status = 'pending'),
    'in_review', count(*) filter (where status = 'in_review'),
    'replied', count(*) filter (where status = 'replied'),
    'closed', count(*) filter (where status = 'closed'),
    'unmatched', (select count(*) from public.unmatched_replies where resolved_at is null)
  ) into v
  from public.kyc_requests;
  return v;
end;
$$;

revoke all on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Admin ticket listing with the owner's profile joined in (admin only)
-- ---------------------------------------------------------------------------
create or replace function public.admin_ticket_list()
returns table (
  id uuid,
  ticket_code text,
  user_id uuid,
  user_email text,
  user_display_name text,
  tango_profile_link text,
  register_type public.register_type,
  register_value text,
  status public.kyc_status,
  created_at timestamptz,
  updated_at timestamptz,
  last_reply_at timestamptz,
  message_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
  select r.id,
         r.ticket_code,
         r.user_id,
         p.email,
         p.display_name,
         r.tango_profile_link,
         r.register_type,
         r.register_value,
         r.status,
         r.created_at,
         r.updated_at,
         r.last_reply_at,
         (select count(*) from public.messages m where m.ticket_id = r.id)
    from public.kyc_requests r
    left join public.profiles p on p.id = r.user_id
   order by r.created_at desc;
end;
$$;

revoke all on function public.admin_ticket_list() from public, anon;
grant execute on function public.admin_ticket_list() to authenticated, service_role;
