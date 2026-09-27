-- Tango KYC Verification - a request is only *officially submitted* once its
-- MVola payment has been validated by an admin.
--
-- Business rule enforced here (server side, never from the client):
--   * creating a request with MVola enabled marks it "payment required" and the
--     user is told to pay; nothing is reported as submitted yet;
--   * only an admin approval of the payment promotes the request to
--     "officially submitted", which is the single moment the admin email, the
--     user email and the in-app notifications are produced;
--   * a refused / failed / expired / cancelled payment never promotes it.
--
-- No new column or enum value is introduced: "officially submitted" is derived
-- from the existence of an approved `mvola_payments` row for the ticket, and the
-- existing `payment_required` flag already represents "created / payment
-- pending". The change is therefore limited to the notification triggers and one
-- read-only admin listing.
--
-- Idempotency is unchanged and re-used: every notification carries the same
-- dedupe key it had before, so a replayed webhook or a retried admin action
-- cannot produce a second email or a second notification.

-- ---------------------------------------------------------------------------
-- Ticket created -> history seed + "pay to finalise" notification.
--
-- When MVola is enabled a fresh request becomes payment-required and is NOT
-- announced as submitted: the user is asked to pay. Only an approved payment
-- later emits the "submitted" notification (see on_mvola_payment_updated).
-- When MVola is disabled the previous behaviour is preserved verbatim, so the
-- system still works with payments switched off.
-- ---------------------------------------------------------------------------
create or replace function public.on_kyc_request_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment_enabled boolean := false;
  v_cfg jsonb;
begin
  -- The synthetic welcome ticket is not a genuine submission.
  if new.register_value = 'WELCOME' then
    return new;
  end if;

  insert into public.kyc_status_history (ticket_id, from_status, to_status, actor, actor_role)
  values (new.id, null, new.status, new.user_id, 'user');

  select value into v_cfg from public.app_settings where key = 'mvola';
  v_payment_enabled := coalesce((v_cfg ->> 'enabled')::boolean, false);

  if v_payment_enabled then
    -- A request may still be awaiting payment, so it is explicitly flagged and
    -- the user is told the payment is required to finalise the submission.
    update public.kyc_requests
       set payment_required = true,
           payment_requested_at = coalesce(payment_requested_at, now())
     where id = new.id;

    perform public.notify_user(
      new.user_id,
      'payment_requested',
      'Paiement requis',
      'Votre demande ' || new.ticket_code || ' est prête. Effectuez le paiement MVola pour finaliser l''envoi.',
      new.id,
      'payment_requested:' || new.id::text
    );
  else
    -- Payments disabled: fall back to the original acknowledgement, unchanged.
    perform public.notify_user(
      new.user_id,
      'request_submitted',
      'Demande envoyée',
      'Votre demande de vérification ' || new.ticket_code || ' a bien été envoyée. '
        || 'Nous la traiterons et vous informerons de chaque étape.',
      new.id,
      'submitted:' || new.id::text
    );
  end if;
  return new;
end;
$$;

drop trigger if exists kyc_requests_on_created on public.kyc_requests;
create trigger kyc_requests_on_created
  after insert on public.kyc_requests
  for each row execute function public.on_kyc_request_created();

-- ---------------------------------------------------------------------------
-- Payment decided -> the request becomes officially submitted on approval.
--
-- The "submitted" notification keeps the same dedupe key as the original
-- creation event (`submitted:<ticket>`), so at most one is ever produced, and
-- it is only ever produced here, on approval.
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
    -- The request is only now officially submitted.
    perform public.notify_user(
      new.user_id,
      'request_submitted',
      'Demande envoyée',
      'Votre demande KYC ' || coalesce(v_code, '') || ' a été envoyée avec succès. '
        || 'Notre équipe va la traiter.',
      new.ticket_id,
      'submitted:' || new.ticket_id::text
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
-- Derived, server-side view of the submission state, so the client and the
-- admin UI never have to infer it from Flutter state.
--
--   payment_status : 'not_required' | 'pending' | 'approved' | 'rejected'
--                    | 'awaiting_submission' | 'none'
--   is_submitted   : true only when the request is officially submitted, i.e.
--                    MVola is disabled OR an approved payment exists.
-- ---------------------------------------------------------------------------
create or replace function public.kyc_submission_state(p_ticket_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_required boolean;
  v_enabled boolean;
  v_status text;
begin
  select payment_required into v_required from public.kyc_requests where id = p_ticket_id;
  select coalesce((value ->> 'enabled')::boolean, false) into v_enabled
    from public.app_settings where key = 'mvola';
  v_enabled := coalesce(v_enabled, false);

  select status::text into v_status
    from public.mvola_payments
   where ticket_id = p_ticket_id
   order by (status = 'approved') desc, created_at desc
   limit 1;

  if not coalesce(v_required, false) then
    v_status := 'not_required';
  elsif v_status is null then
    v_status := 'awaiting_submission';
  end if;

  return jsonb_build_object(
    'payment_status', v_status,
    'is_submitted', (not coalesce(v_required, false)) or v_status = 'approved'
  );
end;
$$;

revoke all on function public.kyc_submission_state(uuid) from public, anon, authenticated;
grant execute on function public.kyc_submission_state(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- admin_ticket_list: expose the derived submission state so the dashboard can
-- show "Paiement en attente" versus "Demande soumise" without trusting any
-- client. The return type changes, which Postgres only allows via DROP+CREATE;
-- every pre-existing column and the ordering are preserved and grants restored.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_ticket_list();

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
  payment_required boolean,
  payment_status text,
  is_submitted boolean,
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
         r.payment_required,
         coalesce(st.s ->> 'payment_status', 'none'),
         coalesce((st.s ->> 'is_submitted')::boolean, true),
         (select count(*) from public.messages m where m.ticket_id = r.id)
    from public.kyc_requests r
    left join public.profiles p on p.id = r.user_id
    cross join lateral (select public.kyc_submission_state(r.id) as s) st
   order by r.created_at desc;
end;
$$;

revoke all on function public.admin_ticket_list() from public, anon;
grant execute on function public.admin_ticket_list() to authenticated, service_role;
