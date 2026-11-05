-- Marque comme lues les notifications de l'utilisateur connecté (toutes, ou une liste)
create or replace function public.mark_my_notifications_read(p_ids uuid[] default null)
 returns integer language plpgsql security definer set search_path to 'public'
as $function$
declare n integer;
begin
  update public.notifications set is_read = true, read_at = now()
   where user_id = auth.uid() and coalesce(is_read, false) = false
     and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end $function$;
grant execute on function public.mark_my_notifications_read(uuid[]) to authenticated;
