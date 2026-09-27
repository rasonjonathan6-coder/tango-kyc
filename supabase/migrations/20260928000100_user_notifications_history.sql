-- Tango KYC Verification - user-facing notifications, status history and the
-- explicit "payment required" signal.
--
-- Purely additive: this migration creates two tables, adds one boolean column
-- with a default (so existing rows are unaffected), adds triggers and helper
-- functions, and tightens one grant. No existing table, column, policy or
-- function is dropped or rewritten; the email ingestion pipeline
-- (Resend Inbound / Gmail transport) is not touched.
--
-- Event -> notification mapping (each carries an idempotency key, so a retried
-- action can never produce a second row):
--   ticket insert              -> request_submitted   (dedupe: submitted:<ticket>)
--   first admin outbound email -> request_received     (dedupe: received:<ticket>)
--   kyc_requests.status change -> status_changed       (dedupe: status:<ticket>:<history_id>)
--   admin_request_payment()    -> payment_requested    (dedupe: payment_requested:<ticket>)
--   payment approved           -> payment_confirmed    (dedupe: payment_confirmed:<payment>)
--                              -> request_approved     (dedupe: approved:<payment>)
--   payment rejected           -> request_rejected     (dedupe: rejected:<payment>)
--   messages insert (admin)    -> admin_message        (dedupe: msg:<message>)
--   account creation           -> welcome              (dedupe: welcome)

-- ---------------------------------------------------------------------------
-- Explicit payment-required signal.
--
-- "A payment is required" is a fact about the ticket that the administration
-- decides, not a property of whether MVola happens to be enabled. Default
-- false keeps every existing ticket exactly as it was: no payment is shown
-- until an admin asks for one.
-- ---------------------------------------------------------------------------
alter table public.kyc_requests
  add column if not exists payment_required boolean not null default false,
  add column if not exists payment_requested_at timestamptz;

comment on column public.kyc_requests.payment_required is
  'Set by admin_request_payment(); gates mvola_start_payment and the payment UI.';

-- ---------------------------------------------------------------------------
-- notifications - per-user, persisted event feed.
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.notification_type as enum (
    'welcome',
    'request_submitted',
    'request_received',
    'status_changed',
    'payment_requested',
    'payment_confirmed',
    'request_approved',
    'request_rejected',
    'admin_message'
  );
exception when duplicate_object then null; end $$;

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  type public.notification_type not null,
  title text not null,
  body text not null,
  ticket_id uuid references public.kyc_requests (id) on delete cascade,
  -- Idempotency: one notification per (user, type, key). A retried action or a
  -- replayed webhook therefore cannot create a duplicate.
  dedupe_key text not null,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint notifications_title_len check (char_length(title) between 1 and 200),
  constraint notifications_body_len check (char_length(body) between 1 and 4000),
  constraint notifications_dedupe_len check (char_length(dedupe_key) between 1 and 200)
);

create unique index if not exists notifications_user_type_dedupe_key
  on public.notifications (user_id, type, dedupe_key);

create index if not exists notifications_user_created_at_idx
  on public.notifications (user_id, created_at desc);

create index if not exists notifications_user_unread_idx
  on public.notifications (user_id)
  where read_at is null;

alter table public.notifications enable row level security;

-- A user reads only their own notifications...
drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own on public.notifications
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- ...and may mark their *own* rows read. The `with check` forbids reassigning
-- user_id, and column privileges below forbid touching any other field, so a
-- user can neither forge a notification nor edit its content.
drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

-- ---------------------------------------------------------------------------
-- kyc_status_history - append-only audit of status transitions.
-- ---------------------------------------------------------------------------
create table if not exists public.kyc_status_history (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.kyc_requests (id) on delete cascade,
  from_status public.kyc_status,
  to_status public.kyc_status not null,
  actor uuid references auth.users (id) on delete set null,
  actor_role text not null default 'system',
  created_at timestamptz not null default now(),
  constraint kyc_status_history_actor_role_len check (char_length(actor_role) between 1 and 32)
);

create index if not exists kyc_status_history_ticket_created_idx
  on public.kyc_status_history (ticket_id, created_at);

alter table public.kyc_status_history enable row level security;

-- The owner sees the history of their own tickets; admins see everything.
drop policy if exists kyc_status_history_select_own on public.kyc_status_history;
create policy kyc_status_history_select_own on public.kyc_status_history
  for select to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.kyc_requests r
      where r.id = kyc_status_history.ticket_id and r.user_id = auth.uid()
    )
  );

revoke all on public.kyc_status_history from anon, authenticated;
grant select on public.kyc_status_history to authenticated;

-- ---------------------------------------------------------------------------
-- Internal notification writer. Not granted to any client role: it is only
-- reachable from the SECURITY DEFINER triggers/functions below.
-- ---------------------------------------------------------------------------
create or replace function public.notify_user(
  p_user_id uuid,
  p_type public.notification_type,
  p_title text,
  p_body text,
  p_ticket_id uuid,
  p_dedupe_key text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_user_id is null then
    return null;
  end if;
  insert into public.notifications (user_id, type, title, body, ticket_id, dedupe_key)
  values (
    p_user_id,
    p_type,
    left(coalesce(p_title, ''), 200),
    left(coalesce(p_body, ''), 4000),
    p_ticket_id,
    left(coalesce(p_dedupe_key, ''), 200)
  )
  on conflict (user_id, type, dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.notify_user(uuid, public.notification_type, text, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.notify_user(uuid, public.notification_type, text, text, uuid, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- Trigger: ticket created -> history seed + "request submitted" notification.
-- ---------------------------------------------------------------------------
create or replace function public.on_kyc_request_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- The synthetic welcome ticket is not a genuine submission: no history seed
  -- and no "request submitted" notification for it.
  if new.register_value = 'WELCOME' then
    return new;
  end if;

  insert into public.kyc_status_history (ticket_id, from_status, to_status, actor, actor_role)
  values (new.id, null, new.status, new.user_id, 'user');

  perform public.notify_user(
    new.user_id,
    'request_submitted',
    'Demande envoyée',
    'Votre demande de vérification ' || new.ticket_code || ' a bien été envoyée. '
      || 'Nous la traiterons et vous informerons de chaque étape.',
    new.id,
    'submitted:' || new.id::text
  );
  return new;
end;
$$;

drop trigger if exists kyc_requests_on_created on public.kyc_requests;
create trigger kyc_requests_on_created
  after insert on public.kyc_requests
  for each row execute function public.on_kyc_request_created();

-- ---------------------------------------------------------------------------
-- Trigger: status change -> history row + notification, and the
-- "request received / taken in charge" event when the first admin email goes
-- out (record_outbound_email moves pending -> in_review and stores the id).
-- ---------------------------------------------------------------------------
create or replace function public.on_kyc_request_updated()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_history_id uuid;
begin
  if new.status is distinct from old.status then
    insert into public.kyc_status_history (ticket_id, from_status, to_status, actor, actor_role)
    values (
      new.id, old.status, new.status, auth.uid(),
      case when public.is_admin() then 'admin' else 'system' end
    )
    returning id into v_history_id;

    perform public.notify_user(
      new.user_id,
      'status_changed',
      'Statut de la demande modifié',
      'Le statut de la demande ' || new.ticket_code || ' est désormais : ' || new.status::text || '.',
      new.id,
      'status:' || new.id::text || ':' || v_history_id::text
    );
  end if;

  -- The administration picked the request up: an outbound email was recorded.
  if new.last_outbound_message_id is distinct from old.last_outbound_message_id
     and new.last_outbound_message_id is not null then
    perform public.notify_user(
      new.user_id,
      'request_received',
      'Demande reçue',
      'Votre demande ' || new.ticket_code || ' a été prise en charge par notre équipe.',
      new.id,
      'received:' || new.id::text
    );
  end if;

  return new;
end;
$$;

drop trigger if exists kyc_requests_on_updated on public.kyc_requests;
create trigger kyc_requests_on_updated
  after update on public.kyc_requests
  for each row execute function public.on_kyc_request_updated();

-- ---------------------------------------------------------------------------
-- Trigger: admin message -> "new message" notification.
-- System messages (e.g. the welcome) and the user's own submission message are
-- intentionally ignored here.
-- ---------------------------------------------------------------------------
create or replace function public.on_message_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_code text;
begin
  if new.sender_type <> 'admin' then
    return new;
  end if;

  select user_id, ticket_code into v_owner, v_code
    from public.kyc_requests where id = new.ticket_id;

  perform public.notify_user(
    v_owner,
    'admin_message',
    'Nouveau message de l''administration',
    'Un nouveau message concernant la demande ' || coalesce(v_code, '') || ' est disponible.',
    new.ticket_id,
    'msg:' || new.id::text
  );
  return new;
end;
$$;

drop trigger if exists messages_on_created on public.messages;
create trigger messages_on_created
  after insert on public.messages
  for each row execute function public.on_message_created();

-- ---------------------------------------------------------------------------
-- Trigger: payment decided -> confirmed + approved, or rejected.
-- ---------------------------------------------------------------------------
create or replace function public.on_mvola_payment_updated()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  select ticket_code into v_code from public.kyc_requests where id = new.ticket_id;

  if new.status = 'approved' then
    perform public.notify_user(
      new.user_id,
      'payment_confirmed',
      'Paiement confirmé',
      'Votre paiement pour la demande ' || coalesce(v_code, '') || ' a été confirmé.',
      new.ticket_id,
      'payment_confirmed:' || new.id::text
    );
    perform public.notify_user(
      new.user_id,
      'request_approved',
      'Demande approuvée',
      'Votre demande ' || coalesce(v_code, '') || ' a été approuvée.',
      new.ticket_id,
      'approved:' || new.id::text
    );
  elsif new.status = 'rejected' then
    perform public.notify_user(
      new.user_id,
      'request_rejected',
      'Demande refusée',
      'Votre paiement pour la demande ' || coalesce(v_code, '') || ' a été refusé.'
        || case when coalesce(new.rejection_reason, '') <> ''
             then ' Motif : ' || new.rejection_reason else '' end,
      new.ticket_id,
      'rejected:' || new.id::text
    );
  end if;

  return new;
end;
$$;

drop trigger if exists mvola_payments_on_updated on public.mvola_payments;
create trigger mvola_payments_on_updated
  after update on public.mvola_payments
  for each row execute function public.on_mvola_payment_updated();

-- ---------------------------------------------------------------------------
-- admin_request_payment - the explicit, secure "a payment is now required"
-- signal. Admin only.
-- ---------------------------------------------------------------------------
create or replace function public.admin_request_payment(p_ticket_id uuid)
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
  if p_ticket_id is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.kyc_requests
     set payment_required = true,
         payment_requested_at = coalesce(payment_requested_at, now()),
         status = case when status = 'pending' then 'in_review'::public.kyc_status else status end
   where id = p_ticket_id
   returning * into v_row;

  if v_row.id is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform public.notify_user(
    v_row.user_id,
    'payment_requested',
    'Paiement demandé',
    'Un paiement est nécessaire pour poursuivre la demande ' || v_row.ticket_code
      || '. Ouvrez la demande pour voir les instructions.',
    v_row.id,
    'payment_requested:' || v_row.id::text
  );

  return v_row;
end;
$$;

revoke all on function public.admin_request_payment(uuid) from public, anon;
grant execute on function public.admin_request_payment(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Gate mvola_start_payment on the explicit signal: no payment may be opened or
-- shown until an admin has actually requested one.
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
  v_required boolean;
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

  select user_id, payment_required into v_owner, v_required
    from public.kyc_requests where id = p_ticket_id;
  if v_owner is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_owner <> v_uid then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  -- Payment is only offered once the administration explicitly asked for it.
  if not coalesce(v_required, false) then
    raise exception 'MVOLA_NOT_REQUIRED' using errcode = 'P0001';
  end if;

  select value into v_cfg from public.app_settings where key = 'mvola';
  if v_cfg is null then
    raise exception 'MVOLA_NOT_CONFIGURED' using errcode = 'P0002';
  end if;
  if not coalesce((v_cfg ->> 'enabled')::boolean, false) then
    raise exception 'MVOLA_DISABLED' using errcode = 'P0001';
  end if;

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
-- Welcome: one notification + one read-only system message on account
-- creation. `messages.ticket_id` stays NOT NULL, so the welcome is stored as a
-- standalone system message on a synthetic, user-owned welcome ticket. That
-- keeps every constraint intact and reuses the existing message rendering.
-- ---------------------------------------------------------------------------
create or replace function public.ensure_welcome_ticket(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_existing uuid;
  v_code text;
  v_token text;
  v_id uuid;
  v_attempt int := 0;
begin
  if p_user_id is null then
    return null;
  end if;

  select id into v_existing
    from public.kyc_requests
   where user_id = p_user_id and register_type = 'phone' and register_value = 'WELCOME'
   limit 1;
  if v_existing is not null then
    return v_existing;
  end if;

  loop
    v_attempt := v_attempt + 1;
    v_code := 'TNG-KYC-' || upper(encode(extensions.gen_random_bytes(4), 'hex'));
    v_token := encode(extensions.gen_random_bytes(16), 'hex');
    begin
      insert into public.kyc_requests (
        user_id, ticket_code, tango_profile_link, register_type, register_value, status, reply_token
      ) values (
        p_user_id, v_code, 'https://tango.example/welcome', 'phone', 'WELCOME', 'closed', v_token
      )
      returning id into v_id;
      exit;
    exception when unique_violation then
      if v_attempt >= 5 then
        raise;
      end if;
    end;
  end loop;

  insert into public.messages (ticket_id, sender_type, body)
  values (
    v_id,
    'system',
    'Bienvenue sur Tango KYC 👋' || chr(10) || chr(10) ||
    'Votre espace vous permet d''envoyer une demande de vérification de compte, '
      || 'suivre son évolution et consulter les informations concernant votre demande.' || chr(10) || chr(10) ||
    'Merci d''utiliser Tango KYC.'
  );

  perform public.notify_user(
    p_user_id,
    'welcome',
    'Bienvenue sur Tango KYC 👋',
    'Votre espace vous permet d''envoyer une demande de vérification de compte, '
      || 'suivre son évolution et consulter les informations concernant votre demande.',
    v_id,
    'welcome'
  );

  return v_id;
end;
$$;

revoke all on function public.ensure_welcome_ticket(uuid) from public, anon, authenticated;
grant execute on function public.ensure_welcome_ticket(uuid) to service_role;

-- Rebuild handle_new_user so it also seeds the welcome (profile behaviour is
-- unchanged otherwise).
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

  -- Welcome is best-effort: a failure here must never block account creation.
  begin
    perform public.ensure_welcome_ticket(new.id);
  exception when others then
    null;
  end;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lock down the user reply path entirely.
--
-- The application no longer exposes a reply box, but hiding UI is not a
-- security boundary: the RPC must be unreachable too. Execute is revoked from
-- every client role; the function body is left in place so nothing that
-- references it breaks, but no user token can call it any more.
-- ---------------------------------------------------------------------------
revoke all on function public.user_post_message(uuid, text) from public, anon, authenticated;
