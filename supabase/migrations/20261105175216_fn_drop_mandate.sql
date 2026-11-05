-- Diffusion d'un mandat depuis la création (brouillon / nouveau / liste de drop)
-- via la machine à états : draft|new -> drop_pending -> dropped (listes facultatives)
create or replace function public.drop_mandate(p_mandate_id uuid, p_list_ids uuid[] default null)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_status mandate_status;
begin
  select status into v_status from public.mandates where id = p_mandate_id;
  if not found then raise exception 'Mandat introuvable'; end if;
  if v_status in ('draft','new') then
    perform public.transition_mandate_status(p_mandate_id, 'drop_pending');
  end if;
  perform public.transition_mandate_status(p_mandate_id, 'dropped', null, null, 'manual', p_list_ids);
end $function$;
grant execute on function public.drop_mandate(uuid, uuid[]) to authenticated;
