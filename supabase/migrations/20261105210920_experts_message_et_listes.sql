-- Liste d'experts (CC E) : message à des experts choisis + ajout à des listes
drop function if exists public.manager_broadcast(text,text,text,uuid[],boolean,boolean);

create or replace function public.manager_broadcast(
    p_type text, p_audience text, p_message text,
    p_mandate_ids uuid[] default '{}'::uuid[], p_unassign boolean default false, p_uncloud boolean default false,
    p_expert_ids uuid[] default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
    v_id uuid := gen_random_uuid(); v_title text;
    v_recipients int := 0; v_unassigned int := 0; v_uncloud int := 0; v_m record;
    v_targeted boolean := cardinality(coalesce(p_expert_ids,'{}')) > 0;
begin
    if auth.uid() is null then raise exception 'Utilisateur non connecté'; end if;
    if not public.is_manager() then raise exception 'Le message groupé est réservé aux gestionnaires'; end if;

    v_title := case p_type when 'alerte' then 'Alerte' when 'anomalie' then 'Anomalie' when 'nouveautes' then 'Nouveautés' end;
    if v_title is null then raise exception 'Type de message invalide : %', p_type; end if;
    if not v_targeted and coalesce(p_audience,'') not in ('connected','all') then raise exception 'Destinataires invalides : %', p_audience; end if;
    if nullif(trim(coalesce(p_message,'')), '') is null then raise exception 'Le message est obligatoire'; end if;
    if (p_unassign or p_uncloud) and cardinality(coalesce(p_mandate_ids,'{}')) = 0 then
        raise exception 'Cochez au moins un mandat pour retirer l''attribution ou sortir du cloud';
    end if;

    -- Destinataires : experts choisis (Liste d'experts) ou connectés / tous (Current_drop)
    insert into public.notifications (user_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
    select e.user_id, 'message', v_title, trim(p_message), 'in_app', false, now(), 'broadcast', v_id, 'dashboard'
      from public.experts e
     where e.user_id is not null
       and (case when v_targeted then e.id = any(p_expert_ids)
                 else (p_audience = 'all' or e.status_experts = 'connecte') end);
    get diagnostics v_recipients = row_count;

    if p_unassign then
        for v_m in select m.id, m.reference, e.user_id as expert_user
                     from public.mandates m left join public.experts e on e.id = m.assigned_expert_id
                    where m.id = any(p_mandate_ids) and m.status in ('assigned','in_progress') loop
            if v_m.expert_user is not null then
                insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
                values (v_m.expert_user, v_m.id, 'status_change', 'Attribution retirée',
                        'Le mandat ' || coalesce(v_m.reference,'') || ' vous a été retiré. ' || trim(p_message),
                        'in_app', false, now(), 'broadcast', v_id, 'mandate');
            end if;
            perform public.transition_mandate_status(v_m.id, 'redrop');
            v_unassigned := v_unassigned + 1;
        end loop;
    end if;

    if p_uncloud then
        for v_m in select m.id from public.mandates m where m.id = any(p_mandate_ids) and m.status in ('dropped','redrop') loop
            perform public.transition_mandate_status(v_m.id, 'drop_pending');
            v_uncloud := v_uncloud + 1;
        end loop;
    end if;

    insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
    values (auth.uid(), 'broadcast', v_id, 'group_message',
            jsonb_build_object('type', p_type, 'audience', case when v_targeted then 'selected' else p_audience end,
                               'message', trim(p_message), 'recipients', v_recipients, 'expert_ids', p_expert_ids,
                               'mandate_ids', p_mandate_ids, 'unassign', p_unassign, 'unassigned', v_unassigned,
                               'uncloud', p_uncloud, 'uncloud_count', v_uncloud));

    return jsonb_build_object('broadcast_id', v_id, 'recipients', v_recipients, 'unassigned', v_unassigned, 'uncloud', v_uncloud);
end;
$function$;
grant execute on function public.manager_broadcast(text,text,text,uuid[],boolean,boolean,uuid[]) to authenticated;

-- Ajout d'experts à des listes manuelles de l'organisation du gestionnaire
create or replace function public.add_experts_to_lists(p_expert_ids uuid[], p_list_ids uuid[])
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if cardinality(coalesce(p_expert_ids,'{}')) = 0 then raise exception 'Cochez au moins un expert'; end if;
  if cardinality(coalesce(p_list_ids,'{}')) = 0 then raise exception 'Choisissez au moins une liste'; end if;
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
end $$;
grant execute on function public.add_experts_to_lists(uuid[], uuid[]) to authenticated;
