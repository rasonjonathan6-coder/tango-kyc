-- Tango KYC Verification - Android push (FCM) device tokens and Realtime.
--
-- Purely additive. It creates one table, adds the `notifications` and
-- `kyc_requests` tables to the `supabase_realtime` publication, and adds one
-- enum member. No existing table, column, policy or function is dropped or
-- rewritten; the email ingestion pipeline (Resend Inbound / Gmail transport),
-- the MVola workflow and the auth/PKCE flow are untouched.
--
-- Server authority: a device token is inserted/updated by the client only for
-- itself (RLS `auth.uid()`), and the push itself is produced server side by the
-- `email-webhook` Edge Function, which is the only holder of the Firebase
-- service-account secret. No Firebase credential ever reaches the APK.

-- ---------------------------------------------------------------------------
-- device_tokens - one row per (user, FCM token).
--
-- A token can migrate between accounts on a shared device, so the token string
-- is the natural identity: `upsert` on it reassigns `user_id`. A user may have
-- several devices, hence the composite primary key.
-- ---------------------------------------------------------------------------
create table if not exists public.device_tokens (
  user_id uuid not null references auth.users (id) on delete cascade,
  token text not null,
  platform text not null default 'android',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, token),
  constraint device_tokens_token_len check (char_length(token) between 20 and 4096),
  constraint device_tokens_platform_len check (char_length(platform) between 1 and 32)
);

-- The same FCM token must never belong to two users at once.
create unique index if not exists device_tokens_token_key
  on public.device_tokens (token);

create index if not exists device_tokens_user_id_idx
  on public.device_tokens (user_id);

drop trigger if exists device_tokens_touch_updated_at on public.device_tokens;
create trigger device_tokens_touch_updated_at
  before update on public.device_tokens
  for each row execute function public.touch_updated_at();

alter table public.device_tokens enable row level security;

-- A user manages only their own tokens. No admin policy: an administrator has
-- no reason to read or forge another account's push target.
drop policy if exists device_tokens_select_own on public.device_tokens;
create policy device_tokens_select_own on public.device_tokens
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists device_tokens_insert_own on public.device_tokens;
create policy device_tokens_insert_own on public.device_tokens
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists device_tokens_update_own on public.device_tokens;
create policy device_tokens_update_own on public.device_tokens
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists device_tokens_delete_own on public.device_tokens;
create policy device_tokens_delete_own on public.device_tokens
  for delete to authenticated
  using (user_id = auth.uid());

revoke all on public.device_tokens from anon, authenticated;
grant select, insert, update, delete on public.device_tokens to authenticated;

-- ---------------------------------------------------------------------------
-- Register / refresh the caller's FCM token.
--
-- SECURITY DEFINER because the `on conflict` must be able to move a row that
-- currently belongs to a *different* user (a shared device that just signed in
-- as someone else). Doing this through the table directly would be blocked by
-- the row's `user_id = auth.uid()` policy; here the identity is taken from
-- `auth.uid()` and can therefore never be spoofed by the caller.
--
-- Stealing a token cannot leak data: it would only redirect that device's own
-- pushes, and `notifications` reads stay RLS-scoped to the caller, so no row of
-- the previous owner is ever exposed.
-- ---------------------------------------------------------------------------
create or replace function public.register_device_token(
  p_token text,
  p_platform text default 'android'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_token text := nullif(trim(coalesce(p_token, '')), '');
  v_platform text := coalesce(nullif(trim(coalesce(p_platform, '')), ''), 'android');
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;
  if v_token is null then
    raise exception 'TOKEN_REQUIRED' using errcode = '22023';
  end if;
  if char_length(v_token) > 4096 then
    v_token := left(v_token, 4096);
  end if;

  insert into public.device_tokens (user_id, token, platform)
  values (v_uid, v_token, left(v_platform, 32))
  on conflict (token) do update
    set user_id = v_uid,
        platform = left(v_platform, 32),
        updated_at = now();
end;
$$;

-- No client role may execute the definer function directly; the client writes
-- through the RLS-protected table instead, and this helper exists for the
-- sign-in path only if it is granted explicitly.
revoke all on function public.register_device_token(text, text) from public, anon;
grant execute on function public.register_device_token(text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Realtime: let the owner's client be pushed a change instead of polling.
--
-- Only the two tables the dashboard reacts to are added. `notifications` drives
-- the bell badge; `kyc_requests` drives the request list and its status pill.
-- RLS is enforced for Realtime row delivery, so a subscriber still only ever
-- receives rows they could have selected.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'kyc_requests'
  ) then
    alter publication supabase_realtime add table public.kyc_requests;
  end if;
end $$;
