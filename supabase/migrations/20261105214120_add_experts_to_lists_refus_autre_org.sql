CREATE OR REPLACE FUNCTION public.add_experts_to_lists(p_expert_ids uuid[], p_list_ids uuid[])
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare n integer;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if cardinality(coalesce(p_expert_ids,'{}')) = 0 then raise exception 'Cochez au moins un expert'; end if;
  if cardinality(coalesce(p_list_ids,'{}')) = 0 then raise exception 'Choisissez au moins une liste'; end if;
  if exists (select 1 from unnest(p_list_ids) x
              where not exists (select 1 from public.expert_lists l
                                 where l.id = x and l.organization_id = public.current_user_organization_id())) then
    raise exception 'Liste introuvable dans votre organisation';
  end if;
  if exists (select 1 from public.expert_lists where id = any(p_list_ids) and auto_rule is not null) then
    raise exception 'Les listes automatiques (KPI, agréments) se remplissent seules et ne peuvent pas être modifiées à la main';
  end if;
  insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
  select l.id, e.id, auth.uid()
    from public.expert_lists l cross join public.experts e
   where l.id = any(p_list_ids) and l.organization_id = public.current_user_organization_id()
     and e.id = any(p_expert_ids)
  on conflict (list_id, expert_id) do nothing;
  get diagnostics n = row_count;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', gen_random_uuid(), 'experts_added_to_lists',
          jsonb_build_object('expert_ids', p_expert_ids, 'list_ids', p_list_ids, 'added', n));
  return n;
end $function$;
