-- Durcissement canonique de public.user_post_message.
--
-- Règle métier appliquée côté serveur, jamais depuis le client :
--   * l'appelant doit être authentifié et propriétaire du ticket ;
--   * un ticket fermé est en lecture seule ;
--   * lorsque le paiement est requis, il doit avoir été approuvé par un admin
--     avant toute réponse de l'utilisateur ;
--   * rate limit de 5 messages utilisateur par minute ;
--   * corps limité à 20 000 caractères.
--
-- La confirmation du paiement est dérivée des données serveur uniquement : une
-- ligne `mvola_payments` au statut `approved` pour ce ticket. Aucune valeur
-- fournie par le client n'est utilisée et aucune colonne n'est ajoutée.
--
-- La lecture du ticket se fait en `for update`, dans la même instruction que les
-- contrôles, afin qu'une fermeture ou une décision de paiement concurrente ne
-- puisse pas s'intercaler entre la vérification et l'insertion.
--
-- Remplace la définition d'origine (20260925000200_email_and_actions.sql) sans
-- dépendre des migrations contradictoires 20260929000100 / 20260930000100 /
-- 20260930000200, qui restent non appliquées.
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
  v_status public.kyc_status;
  v_payment_required boolean;
  v_is_submitted boolean;
  v_recent int;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;
  if v_body is null then
    raise exception 'MESSAGE_REQUIRED' using errcode = '22023';
  end if;

  select user_id,
         status,
         payment_required,
         (not payment_required) or exists (
           select 1
             from public.mvola_payments p
            where p.ticket_id = kyc_requests.id
              and p.status = 'approved'
         )
    into v_owner, v_status, v_payment_required, v_is_submitted
    from public.kyc_requests
   where id = p_ticket_id
   for update;
  if v_owner is null then
    raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_owner <> auth.uid() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_status = 'closed' then
    raise exception 'TICKET_CLOSED' using errcode = 'P0001';
  end if;
  if v_payment_required and not v_is_submitted then
    raise exception 'PAYMENT_NOT_CONFIRMED' using errcode = 'P0003';
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
