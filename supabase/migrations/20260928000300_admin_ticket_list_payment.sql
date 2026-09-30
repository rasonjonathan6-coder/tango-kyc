-- Extend admin_ticket_list with the payment_required flag so the admin UI can
-- show whether a payment has been requested. The return type gains one column,
-- which Postgres only allows via DROP + CREATE; every pre-existing column and
-- the ordering are kept identical, and the grants are restored. This function
-- is read-only and only reachable by authenticated admins (is_admin() is
-- asserted inside).
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
         (select count(*) from public.messages m where m.ticket_id = r.id)
    from public.kyc_requests r
    left join public.profiles p on p.id = r.user_id
   order by r.created_at desc;
end;
$$;

revoke all on function public.admin_ticket_list() from public, anon;
grant execute on function public.admin_ticket_list() to authenticated, service_role;
