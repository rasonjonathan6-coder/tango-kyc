-- Tango KYC Verification - manual MVola payment system.
--
-- MVola is a *manual* flow: the user transfers money from their own MVola wallet
-- to a configured recipient number, then submits the transaction reference. No
-- MVola API is called and a payment is never considered settled because the
-- client said so - an admin reviews it.
--
-- Amount, recipient number, currency, USSD template and instructions are
-- configuration, not code: they live in the `mvola` row of `app_settings` and
-- can be changed without a redeploy or an app release.
--
-- This migration is purely additive. It creates one table, its policies, its
-- indexes and its functions. No existing table, policy, function or secret is
-- altered.
--
-- Status model (documented so the client and the admin UI agree):
--   pending   - the payment exists and is the active payment for its ticket.
--               `submitted_at is null`  -> the user has not confirmed yet.
--               `submitted_at not null` -> awaiting admin verification.
--   approved  - an admin verified the transfer. Terminal, and it keeps the
--               ticket's payment step satisfied.
--   rejected  - an admin declined it; `rejection_reason` is mandatory and is
--               shown to the user so they can correct the submission.
--   cancelled - reserved for a future cancellation path. No action sets it yet.

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.mvola_status as enum ('pending', 'approved', 'rejected', 'cancelled');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Configuration helpers
-- ---------------------------------------------------------------------------

-- Renders a money amount for the USSD string without trailing zeros, so
-- 20000.00 becomes "20000" and 1500.50 stays "1500.50".
create or replace function public.mvola_amount_text(p_amount numeric)
returns text
language sql
immutable
as $$
  select case
    when p_amount is null then ''
    when p_amount = trunc(p_amount) then trunc(p_amount)::bigint::text
    else rtrim(rtrim(to_char(p_amount, 'FM999999999990.99'), '0'), '.')
  end;
$$;

-- Builds the dial string from the configurable template, substituting the
-- recipient number and the amount. The template lives in `app_settings` so the
-- USSD syntax can change without touching this function.
create or replace function public.mvola_ussd_code(p_recipient text, p_amount numeric)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select replace(
               replace(v.value ->> 'ussd_template', '{recipient}', coalesce(trim(p_recipient), '')),
               '{amount}',
               public.mvola_amount_text(p_amount)
             )
        from public.app_settings v
       where v.key = 'mvola'
    ),
    ''
  );
$$;

revoke all on function public.mvola_amount_text(numeric) from public, anon;
revoke all on function public.mvola_ussd_code(text, numeric) from public, anon;
grant execute on function public.mvola_amount_text(numeric) to service_role;
grant execute on function public.mvola_ussd_code(text, numeric) to authenticated, service_role;

-- Seed the initial configuration. These are the values the operator supplied;
-- they are defaults, not constants, and are edited with SQL on `app_settings`.
insert into public.app_settings (key, value) values (
  'mvola',
  jsonb_build_object(
    'enabled', true,
    'recipient_number', '0346715622',
    'amount', 20000,
    'currency', 'MGA',
    'ussd_template', '#111*1*2*{recipient}*{amount}*2#',
    'instructions',
      'Open MVola, choose "Pay", then enter the number and the amount shown above. ' ||
      'You can also dial the USSD code directly.'
  )
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- mvola_payments
-- ---------------------------------------------------------------------------
create table if not exists public.mvola_payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  ticket_id uuid not null references public.kyc_requests (id) on delete cascade,
  amount numeric(12, 2) not null,
  currency text not null default 'MGA',
  recipient_number text not null,
  payer_number text,
  transaction_reference text,
  ussd_code text not null,
  status public.mvola_status not null default 'pending',
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users (id) on delete set null,
  constraint mvola_payments_amount_positive check (amount > 0),
  constraint mvola_payments_currency_len check (char_length(currency) between 1 and 8),
  constraint mvola_payments_recipient_len check (char_length(recipient_number) between 3 and 32),
  constraint mvola_payments_payer_len
    check (payer_number is null or char_length(payer_number) between 3 and 32),
  constraint mvola_payments_reference_len
    check (transaction_reference is null or char_length(transaction_reference) between 3 and 64),
  constraint mvola_payments_reference_charset
    check (transaction_reference is null or transaction_reference ~ '^[A-Za-z0-9][A-Za-z0-9 ._/-]*$'),
  constraint mvola_payments_rejection_len
    check (rejection_reason is null or char_length(rejection_reason) between 3 and 500),
  -- A decided payment always records who decided it and when.
  constraint mvola_payments_reviewed_consistency
    check (status not in ('approved', 'rejected') or reviewed_at is not null),
  -- A rejection without an explanation is not actionable for the user.
  constraint mvola_payments_rejected_needs_reason
    check (status <> 'rejected' or rejection_reason is not null)
);

-- Double-payment protection. At most one *live* payment may exist per ticket:
-- a pending one (awaiting confirmation or verification) or an approved one. A
-- rejected payment therefore allows a corrected resubmission, while an approved
-- one can never be re-created for the same ticket.
create unique index if not exists mvola_payments_active_per_ticket_key
  on public.mvola_payments (ticket_id)
  where status in ('pending', 'approved');

create index if not exists mvola_payments_user_id_created_at_idx
  on public.mvola_payments (user_id, created_at desc);
create index if not exists mvola_payments_status_created_at_idx
  on public.mvola_payments (status, created_at desc);
create index if not exists mvola_payments_ticket_id_idx
  on public.mvola_payments (ticket_id);

drop trigger if exists mvola_payments_touch_updated_at on public.mvola_payments;
create trigger mvola_payments_touch_updated_at
  before update on public.mvola_payments
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security
--
-- Same shape as `kyc_requests`: a user reads their own rows, an admin reads
-- everything, and *nobody* writes directly. Every mutation goes through a
-- SECURITY DEFINER function that decides ownership, amount and status server
-- side, so a client cannot forge an approval or move a payment to another user.
-- ---------------------------------------------------------------------------
alter table public.mvola_payments enable row level security;

drop policy if exists mvola_payments_select_own on public.mvola_payments;
create policy mvola_payments_select_own on public.mvola_payments
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

revoke all on public.mvola_payments from anon, authenticated;
grant select on public.mvola_payments to authenticated;

-- ---------------------------------------------------------------------------
-- mvola_config - the payer-facing subset of the configuration.
-- Exposes only what a payer needs; never the internal switch or admin fields.
-- ---------------------------------------------------------------------------
create or replace function public.mvola_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
  v_amount numeric;
  v_recipient text;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;

  select value into v from public.app_settings where key = 'mvola';
  if v is null then
    raise exception 'MVOLA_NOT_CONFIGURED' using errcode = 'P0002';
  end if;
  if not coalesce((v ->> 'enabled')::boolean, false) then
    raise exception 'MVOLA_DISABLED' using errcode = 'P0001';
  end if;

  v_amount := (v ->> 'amount')::numeric;
  v_recipient := trim(coalesce(v ->> 'recipient_number', ''));
  if v_amount is null or v_amount <= 0 or v_recipient = '' then
    raise exception 'MVOLA_NOT_CONFIGURED' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'recipient_number', v_recipient,
    'amount', v_amount,
    'currency', coalesce(nullif(trim(v ->> 'currency'), ''), 'MGA'),
    'ussd_code', public.mvola_ussd_code(v_recipient, v_amount),
    'instructions', coalesce(v ->> 'instructions', '')
  );
end;
$$;

revoke all on function public.mvola_config() from public, anon;
grant execute on function public.mvola_config() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- mvola_start_payment - open (or return) the active payment for a ticket.
--
-- The amount, currency, recipient and USSD code all come from server-side
-- configuration. The client supplies only the ticket id, and never the price.
-- Idempotent: a second call returns the existing live payment instead of
-- creating a duplicate, so a double tap or a reopened app is harmless.
-- ---------------------------------------------------------------------------
create or replace function public.mvola_start_payment(p_ticket_id uuid)
returns public.mvola_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_cfg jsonb;
  v_amount numeric;
  v_currency text;
  v_recipient text;
  v_existing public.mvola_payments;
  v_row public.mvola_payments;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;
  if p_ticket_id is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Ownership is read from the ticket row, never trusted from the client.
  select user_id into v_owner from public.kyc_requests where id = p_ticket_id;
  if v_owner is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_owner <> v_uid then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select value into v_cfg from public.app_settings where key = 'mvola';
  if v_cfg is null then
    raise exception 'MVOLA_NOT_CONFIGURED' using errcode = 'P0002';
  end if;
  if not coalesce((v_cfg ->> 'enabled')::boolean, false) then
    raise exception 'MVOLA_DISABLED' using errcode = 'P0001';
  end if;

  -- Serialise concurrent starts for the same ticket.
  perform pg_advisory_xact_lock(hashtextextended(p_ticket_id::text, 7));

  select * into v_existing
    from public.mvola_payments
   where ticket_id = p_ticket_id
     and status in ('pending', 'approved')
   order by created_at desc
   limit 1;
  if found then
    return v_existing;
  end if;

  v_amount := (v_cfg ->> 'amount')::numeric;
  v_currency := coalesce(nullif(trim(v_cfg ->> 'currency'), ''), 'MGA');
  v_recipient := trim(coalesce(v_cfg ->> 'recipient_number', ''));
  if v_amount is null or v_amount <= 0 or v_recipient = '' then
    raise exception 'MVOLA_NOT_CONFIGURED' using errcode = 'P0002';
  end if;

  insert into public.mvola_payments (
    user_id, ticket_id, amount, currency, recipient_number, ussd_code
  ) values (
    v_uid, p_ticket_id, v_amount, v_currency, v_recipient,
    public.mvola_ussd_code(v_recipient, v_amount)
  )
  returning * into v_row;

  return v_row;
exception when unique_violation then
  -- Lost the race against a concurrent start: return the winner's row.
  select * into v_row
    from public.mvola_payments
   where ticket_id = p_ticket_id
     and status in ('pending', 'approved')
   order by created_at desc
   limit 1;
  if v_row.id is null then
    raise exception 'MVOLA_UNAVAILABLE' using errcode = 'P0001';
  end if;
  return v_row;
end;
$$;

revoke all on function public.mvola_start_payment(uuid) from public, anon;
grant execute on function public.mvola_start_payment(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- mvola_submit_payment - the user confirms they paid and supplies the
-- reference. Only the owner may call it, only while the payment is pending, and
-- only these two fields are writable. Status is untouched.
-- ---------------------------------------------------------------------------
create or replace function public.mvola_submit_payment(
  p_payment_id uuid,
  p_transaction_reference text,
  p_payer_number text
)
returns public.mvola_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_reference text;
  v_payer text;
  v_row public.mvola_payments;
  v_existing public.mvola_payments;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;
  if p_payment_id is null then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_existing from public.mvola_payments where id = p_payment_id;
  if v_existing.id is null then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_existing.user_id <> v_uid then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_existing.status <> 'pending' then
    raise exception 'PAYMENT_ALREADY_REVIEWED' using errcode = 'P0001';
  end if;

  -- Strip control characters and surrounding whitespace; keep the reference
  -- itself faithful so an admin can match it against the MVola statement.
  v_reference := regexp_replace(
    trim(coalesce(p_transaction_reference, '')),
    '[\u0000-\u001f\u007f]', '', 'g'
  );
  v_reference := regexp_replace(v_reference, '\s+', ' ', 'g');
  if v_reference = '' then
    raise exception 'MVOLA_REFERENCE_REQUIRED' using errcode = '22023';
  end if;
  if char_length(v_reference) < 3 or char_length(v_reference) > 64 then
    raise exception 'MVOLA_REFERENCE_INVALID' using errcode = '22023';
  end if;
  if v_reference !~ '^[A-Za-z0-9][A-Za-z0-9 ._/-]*$' then
    raise exception 'MVOLA_REFERENCE_INVALID' using errcode = '22023';
  end if;

  v_payer := trim(coalesce(p_payer_number, ''));
  if v_payer <> '' then
    v_payer := public.normalize_register_value(v_payer);
    if v_payer is null
       or char_length(regexp_replace(v_payer, '[^0-9]', '', 'g')) < 7
       or char_length(regexp_replace(v_payer, '[^0-9]', '', 'g')) > 15 then
      raise exception 'MVOLA_PAYER_INVALID' using errcode = '22023';
    end if;
  else
    v_payer := null;
  end if;

  update public.mvola_payments
     set transaction_reference = v_reference,
         payer_number = v_payer,
         submitted_at = now()
   where id = p_payment_id
   returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.mvola_submit_payment(uuid, text, text) from public, anon;
grant execute on function public.mvola_submit_payment(uuid, text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- admin_mvola_set_decision - approve or reject a submitted payment.
-- Reuses the project's existing admin mechanism (public.is_admin()), so there is
-- no second, parallel admin system to keep in sync.
-- ---------------------------------------------------------------------------
create or replace function public.admin_mvola_set_decision(
  p_payment_id uuid,
  p_decision text,
  p_reason text default null
)
returns public.mvola_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reason text;
  v_row public.mvola_payments;
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_payment_id is null then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    raise exception 'MVOLA_DECISION_INVALID' using errcode = '22023';
  end if;

  v_reason := nullif(regexp_replace(trim(coalesce(p_reason, '')), '\s+', ' ', 'g'), '');
  if p_decision = 'rejected' then
    if v_reason is null then
      raise exception 'MVOLA_REASON_REQUIRED' using errcode = '22023';
    end if;
    if char_length(v_reason) > 500 then
      raise exception 'MVOLA_REASON_INVALID' using errcode = '22023';
    end if;
  else
    -- An approval carries no rejection reason.
    v_reason := null;
  end if;

  update public.mvola_payments
     set status = p_decision::public.mvola_status,
         rejection_reason = v_reason,
         reviewed_at = now(),
         reviewed_by = auth.uid()
   where id = p_payment_id
     and status = 'pending'
   returning * into v_row;

  if v_row.id is null then
    -- Either the payment does not exist or it was already decided. Both are
    -- reported the same way so the API does not leak other users' payment ids.
    raise exception 'PAYMENT_ALREADY_REVIEWED' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

revoke all on function public.admin_mvola_set_decision(uuid, text, text) from public, anon;
grant execute on function public.admin_mvola_set_decision(uuid, text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- admin_mvola_list - every payment with its ticket and owner joined in.
-- ---------------------------------------------------------------------------
create or replace function public.admin_mvola_list()
returns table (
  id uuid,
  ticket_id uuid,
  ticket_code text,
  user_id uuid,
  user_email text,
  user_display_name text,
  amount numeric,
  currency text,
  recipient_number text,
  payer_number text,
  transaction_reference text,
  status public.mvola_status,
  rejection_reason text,
  created_at timestamptz,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid,
  reviewer_email text
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
  select p.id,
         p.ticket_id,
         r.ticket_code,
         p.user_id,
         u.email,
         u.display_name,
         p.amount,
         p.currency,
         p.recipient_number,
         p.payer_number,
         p.transaction_reference,
         p.status,
         p.rejection_reason,
         p.created_at,
         p.submitted_at,
         p.reviewed_at,
         p.reviewed_by,
         a.email
    from public.mvola_payments p
    left join public.kyc_requests r on r.id = p.ticket_id
    left join public.profiles u on u.id = p.user_id
    left join public.profiles a on a.id = p.reviewed_by
   order by
     -- Anything still awaiting a decision is what an admin needs to act on.
     (p.status = 'pending' and p.submitted_at is not null) desc,
     p.created_at desc;
end;
$$;

revoke all on function public.admin_mvola_list() from public, anon;
grant execute on function public.admin_mvola_list() to authenticated, service_role;
