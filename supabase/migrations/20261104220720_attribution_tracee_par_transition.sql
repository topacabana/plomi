drop function if exists public.transition_mandate_status(uuid, mandate_status, uuid, text);

create function public.transition_mandate_status(
    p_mandate_id      uuid,
    p_new_status      mandate_status,
    p_expert_id       uuid            default null,
    p_motif           text            default null,
    p_assignment_type assignment_type default 'manual'
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    v_current  mandate_status;
    v_expert   uuid;
    v_allowed  mandate_status[];
begin
    select status, assigned_expert_id into v_current, v_expert
    from public.mandates where id = p_mandate_id for update;
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
        closed_at = case when p_new_status = 'closed' then now() else closed_at end,
        motif_abandon = coalesce(nullif(p_motif, ''), motif_abandon),
        date_abandon  = case when nullif(p_motif, '') is not null then now() else date_abandon end
    where id = p_mandate_id;

    if p_new_status in ('drop_pending','redrop','cancelled','assigned') then
        update public.mandate_assignments
           set status = 'cancelled', cancelled_at = now(),
               comment = coalesce(comment, 'transition ' || p_new_status)
         where mandate_id = p_mandate_id and status in ('pending','accepted');
    end if;

    if p_new_status = 'assigned' then
        insert into public.mandate_assignments
            (mandate_id, expert_id, assignment_type, assigned_by_user_id, status, assigned_at, accepted_at)
        values
            (p_mandate_id, p_expert_id, p_assignment_type, auth.uid(),
             case when p_assignment_type = 'manual' then 'pending'::assignment_status else 'accepted'::assignment_status end,
             now(),
             case when p_assignment_type = 'manual' then null else now() end);
    end if;

    if p_new_status = 'in_progress' then
        update public.mandate_assignments
           set status = 'accepted', accepted_at = now()
         where mandate_id = p_mandate_id and expert_id = v_expert and status = 'pending';
    end if;

    insert into public.activity_logs (entity_type, entity_id, action, old_values_json, new_values_json)
    values ('mandate', p_mandate_id, 'status_transition',
            jsonb_build_object('status', v_current),
            jsonb_build_object('status', p_new_status, 'by', auth.uid(),
                               'expert_id', p_expert_id, 'motif', p_motif,
                               'assignment_type', case when p_new_status = 'assigned' then p_assignment_type end));
end;
$function$;

grant execute on function public.transition_mandate_status(uuid, mandate_status, uuid, text, assignment_type) to authenticated;

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

    perform public.transition_mandate_status(
        p_mandate_id, 'assigned', v_expert_id, null,
        case when v_m.status = 'redrop' then 'redrop'::assignment_type else 'automatic'::assignment_type end
    );

    update public.mandates set selected_slot_at = p_selected_slot_at where id = p_mandate_id;

    select id into v_assignment
    from public.mandate_assignments
    where mandate_id = p_mandate_id and expert_id = v_expert_id and status = 'accepted'
    order by assigned_at desc limit 1;

    return v_assignment;
end;
$function$;

create or replace function public.auto_suspend_overdue_mandates()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    r record;
    n integer := 0;
begin
    for r in
        select m.id
        from public.mandates m
        left join lateral (
            select a.assignment_type
            from public.mandate_assignments a
            where a.mandate_id = m.id and a.status in ('pending','accepted')
            order by a.assigned_at desc limit 1
        ) a on true
        where (m.status = 'assigned' and m.started_at is null and m.assigned_at is not null
               and now() > case
                    when a.assignment_type = 'manual' then m.assigned_at + interval '48 hours'
                    when m.selected_slot_at is not null then m.selected_slot_at + interval '30 minutes'
                    else (date_trunc('day', m.assigned_at at time zone 'Europe/Paris') + interval '1 day') at time zone 'Europe/Paris'
               end)
           or (m.status = 'in_progress' and m.started_at is not null
               and now() > m.started_at + interval '2 hours')
    loop
        perform public.transition_mandate_status(r.id, 'suspended');
        update public.mandates
           set motif_abandon = 'Suspension automatique : délai dépassé', date_abandon = now()
         where id = r.id;
        n := n + 1;
    end loop;
    return n;
end;
$function$;
