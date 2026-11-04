drop function if exists public.transition_mandate_status(uuid, mandate_status, uuid);
create function public.transition_mandate_status(p_mandate_id uuid, p_new_status mandate_status, p_expert_id uuid default null, p_motif text default null)
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
        closed_at = case when p_new_status = 'closed' then now() else closed_at end,
        motif_abandon = coalesce(nullif(p_motif, ''), motif_abandon),
        date_abandon  = case when nullif(p_motif, '') is not null then now() else date_abandon end
    where id = p_mandate_id;

    if p_new_status in ('drop_pending','redrop','cancelled','assigned') then
        update public.mandate_assignments
           set status = 'cancelled', cancelled_at = now(), comment = coalesce(comment, 'transition ' || p_new_status)
         where mandate_id = p_mandate_id and status in ('pending','accepted')
           and (p_new_status <> 'assigned' or expert_id is distinct from p_expert_id);
    end if;

    insert into public.activity_logs (entity_type, entity_id, action, old_values_json, new_values_json)
    values ('mandate', p_mandate_id, 'status_transition',
            jsonb_build_object('status', v_current),
            jsonb_build_object('status', p_new_status, 'by', auth.uid(), 'expert_id', p_expert_id, 'motif', p_motif));
end;
$function$;
grant execute on function public.transition_mandate_status(uuid, mandate_status, uuid, text) to authenticated;
