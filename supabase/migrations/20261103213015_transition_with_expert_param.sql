drop function if exists public.transition_mandate_status(uuid, mandate_status);
create function public.transition_mandate_status(p_mandate_id uuid, p_new_status mandate_status, p_expert_id uuid default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    v_current  mandate_status;
    v_allowed  mandate_status[];
begin
    select status into v_current from public.mandates where id = p_mandate_id for update;
    if not found then
        raise exception 'Mandat introuvable : %', p_mandate_id;
    end if;

    v_allowed := case v_current
        when 'draft'          then array['drop_pending','cancelled']::mandate_status[]
        when 'new'            then array['drop_pending','cancelled']::mandate_status[]
        when 'drop_pending'   then array['dropped','assigned','cancelled']::mandate_status[]
        when 'dropped'        then array['assigned','drop_pending','cancelled']::mandate_status[]
        when 'redrop'         then array['assigned','drop_pending','cancelled']::mandate_status[]
        when 'assigned'       then array['in_progress','drop_pending','suspended','cancelled']::mandate_status[]
        when 'in_progress'    then array['waiting_report','suspended']::mandate_status[]
        when 'waiting_report' then array['closed','redrop','assigned']::mandate_status[]
        when 'suspended'      then array['redrop','assigned','cancelled']::mandate_status[]
        else                       array[]::mandate_status[]
    end;

    if not (p_new_status = any(v_allowed)) then
        raise exception 'Transition interdite : % → % (autorisées : %)', v_current, p_new_status, v_allowed;
    end if;

    if p_new_status = 'assigned' and p_expert_id is null then
        raise exception 'Un expert est requis pour passer en assigned';
    end if;

    update public.mandates set
        status = p_new_status,
        dropped_by = case when p_new_status in ('dropped','redrop') then coalesce(auth.uid(), dropped_by) else dropped_by end,
        started_at = case
            when p_new_status = 'in_progress' then now()
            when p_new_status in ('drop_pending','redrop','assigned') then null
            else started_at end,
        assigned_expert_id = case
            when p_new_status = 'assigned' then p_expert_id
            when p_new_status in ('drop_pending','redrop') then null
            else assigned_expert_id end,
        assigned_at = case
            when p_new_status = 'assigned' then now()
            when p_new_status in ('drop_pending','redrop') then null
            else assigned_at end,
        selected_slot_at = case when p_new_status in ('drop_pending','redrop','assigned') then null else selected_slot_at end,
        closed_at = case when p_new_status = 'closed' then now() else closed_at end
    where id = p_mandate_id;

    -- L'expert précédent perd son assignation
    if p_new_status in ('drop_pending','redrop','cancelled','assigned') then
        update public.mandate_assignments
           set status = 'cancelled', cancelled_at = now(), comment = coalesce(comment, 'transition ' || p_new_status)
         where mandate_id = p_mandate_id and status in ('pending','accepted')
           and (p_new_status <> 'assigned' or expert_id is distinct from p_expert_id);
    end if;

    insert into public.activity_logs (entity_type, entity_id, action, old_values_json, new_values_json)
    values ('mandate', p_mandate_id, 'status_transition',
            jsonb_build_object('status', v_current),
            jsonb_build_object('status', p_new_status, 'by', auth.uid(), 'expert_id', p_expert_id));
end;
$function$;
grant execute on function public.transition_mandate_status(uuid, mandate_status, uuid) to authenticated;

create or replace function public.expert_claim_mandate(p_mandate_id uuid, p_selected_slot_at timestamptz default null)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    v_expert_id  uuid;
    v_m          public.mandates%rowtype;
    v_assignment uuid;
begin
    select id into v_expert_id from public.experts where user_id = auth.uid();
    if not found then
        raise exception 'Aucun profil expert trouvé pour cet utilisateur';
    end if;

    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then
        raise exception 'Mandat introuvable : %', p_mandate_id;
    end if;
    if v_m.status not in ('dropped','redrop') then
        raise exception 'Ce mandat n''est plus disponible (statut actuel : %)', v_m.status;
    end if;

    if coalesce(v_m.slot_1_at, v_m.slot_2_at, v_m.slot_3_at) is not null then
        if p_selected_slot_at is null then
            raise exception 'Veuillez choisir un créneau';
        end if;
        if p_selected_slot_at is distinct from v_m.slot_1_at
           and p_selected_slot_at is distinct from v_m.slot_2_at
           and p_selected_slot_at is distinct from v_m.slot_3_at then
            raise exception 'Créneau invalide pour ce mandat';
        end if;
    end if;

    perform public.transition_mandate_status(p_mandate_id, 'assigned', v_expert_id);

    insert into public.mandate_assignments (mandate_id, expert_id, assignment_type, assigned_by_user_id, status, assigned_at, accepted_at)
    values (p_mandate_id, v_expert_id,
            case when v_m.status = 'redrop' then 'redrop'::assignment_type else 'automatic'::assignment_type end,
            auth.uid(), 'accepted', now(), now())
    returning id into v_assignment;

    update public.mandates set selected_slot_at = p_selected_slot_at where id = p_mandate_id;

    return v_assignment;
end;
$function$;
