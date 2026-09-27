-- Fix: the synthetic welcome ticket must not count towards the per-user
-- submission rate limit, otherwise a freshly created account is told to "wait a
-- few minutes" before it can submit its first real request.
--
-- The rate limit reads max(created_at) and the 24h count over *all* the user's
-- rows. Rather than rewrite that function, the welcome ticket is anchored in the
-- past so it is invisible to both checks. It is a hidden, synthetic, closed row;
-- backdating it changes nothing the user can observe.
update public.kyc_requests
   set created_at = timestamptz '2000-01-01 00:00:00+00',
       updated_at = timestamptz '2000-01-01 00:00:00+00'
 where register_type = 'phone'
   and register_value = 'WELCOME';

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
  -- Far in the past so the welcome row never trips the submission rate limit.
  c_welcome_epoch constant timestamptz := timestamptz '2000-01-01 00:00:00+00';
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
        user_id, ticket_code, tango_profile_link, register_type, register_value,
        status, reply_token, created_at, updated_at
      ) values (
        p_user_id, v_code, 'https://tango.example/welcome', 'phone', 'WELCOME',
        'closed', v_token, c_welcome_epoch, c_welcome_epoch
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
