-- Panneau de notifications : tout marquer comme lu / réinitialiser (vider) l'historique de l'utilisateur connecté
create or replace function public.mark_all_notifications_read()
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  update public.notifications set is_read = true, read_at = greatest(now(), sent_at)
   where user_id = auth.uid() and not is_read;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.clear_my_notifications()
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  delete from public.notifications where user_id = auth.uid();
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.mark_all_notifications_read() from public, anon;
revoke execute on function public.clear_my_notifications() from public, anon;
grant execute on function public.mark_all_notifications_read() to authenticated;
grant execute on function public.clear_my_notifications() to authenticated;
