-- Fix: the synthetic welcome ticket must not emit a "request submitted"
-- notification or a status-history seed. Replaces on_kyc_request_created with
-- the guarded version (also updated in the base migration for fresh installs).
create or replace function public.on_kyc_request_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
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
