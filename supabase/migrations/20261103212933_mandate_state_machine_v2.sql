-- 1. Colonnes créneaux
alter table public.mandates
  add column if not exists slot_1_at timestamptz,
  add column if not exists slot_2_at timestamptz,
  add column if not exists slot_3_at timestamptz,
  add column if not exists selected_slot_at timestamptz;
comment on column public.mandates.slot_1_at is 'Créneau proposé n°1 (heure précise ; affiché au client comme une plage d''1h).';
comment on column public.mandates.slot_2_at is 'Créneau proposé n°2.';
comment on column public.mandates.slot_3_at is 'Créneau proposé n°3.';
comment on column public.mandates.selected_slot_at is 'Créneau choisi par l''expert à la prise en charge. Base de la suspension auto (+30 min).';

-- Correctif : colonnes attendues par les triggers KPI
alter table public.expert_performance_logs
  add column if not exists mandate_id uuid references public.mandates(id) on delete cascade,
  add column if not exists metadata jsonb;

-- 2. Machine d'états
create or replace function public.transition_mandate_status(p_mandate_id uuid, p_new_status mandate_status)
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
        when 'new'            then array['drop_pending','cancelled']::mandate_status[]  -- héritage
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

    update public.mandates set
        status = p_new_status,
        dropped_by = case when p_new_status in ('dropped','redrop') then coalesce(auth.uid(), dropped_by) else dropped_by end,
        started_at = case
            when p_new_status = 'in_progress' then now()
            when p_new_status in ('drop_pending','redrop') then null
            else started_at end,
        assigned_expert_id = case when p_new_status in ('drop_pending','redrop') then null else assigned_expert_id end,
        assigned_at        = case when p_new_status in ('drop_pending','redrop') then null else assigned_at end,
        selected_slot_at   = case when p_new_status in ('drop_pending','redrop') then null else selected_slot_at end,
        closed_at = case when p_new_status = 'closed' then now() else closed_at end
    where id = p_mandate_id;

    -- L'expert précédent perd son assignation
    if p_new_status in ('drop_pending','redrop','cancelled') then
        update public.mandate_assignments
           set status = 'cancelled', cancelled_at = now(), comment = coalesce(comment, 'transition ' || p_new_status)
         where mandate_id = p_mandate_id and status in ('pending','accepted');
    end if;

    insert into public.activity_logs (entity_type, entity_id, action, old_values_json, new_values_json)
    values ('mandate', p_mandate_id, 'status_transition',
            jsonb_build_object('status', v_current),
            jsonb_build_object('status', p_new_status, 'by', auth.uid()));
end;
$function$;

-- 3. Visibilité carte : dropped + redrop
create or replace function public.sync_mandate_visibility()
 returns trigger
 language plpgsql
as $function$
begin
    if new.status in ('dropped','redrop') then
        new.visible_on_map := true;
        if new.drop_at is null then
            new.drop_at := now();
        end if;
    else
        new.visible_on_map := false;
    end if;
    return new;
end;
$function$;

-- 4. Prise en charge expert (avec créneau choisi)
drop function if exists public.expert_claim_mandate(uuid);
create function public.expert_claim_mandate(p_mandate_id uuid, p_selected_slot_at timestamptz default null)
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

    insert into public.mandate_assignments (mandate_id, expert_id, assignment_type, assigned_by_user_id, status, assigned_at, accepted_at)
    values (p_mandate_id, v_expert_id,
            case when v_m.status = 'redrop' then 'redrop'::assignment_type else 'automatic'::assignment_type end,
            auth.uid(), 'accepted', now(), now())
    returning id into v_assignment;

    perform public.transition_mandate_status(p_mandate_id, 'assigned');

    update public.mandates
       set assigned_expert_id = v_expert_id,
           assigned_at = now(),
           selected_slot_at = p_selected_slot_at
     where id = p_mandate_id;

    return v_assignment;
end;
$function$;
grant execute on function public.expert_claim_mandate(uuid, timestamptz) to authenticated;
grant execute on function public.transition_mandate_status(uuid, mandate_status) to authenticated;

-- 5. Escalade de priorité : new -> drop_pending
create or replace function public.escalate_mandate_priority()
 returns void
 language plpgsql
as $function$
begin
  update mandates set priority = 'critical'
   where priority = 'high'   and status in ('draft','drop_pending') and created_at < now() - interval '4 hours';
  update mandates set priority = 'critical'
   where priority = 'medium' and status in ('draft','drop_pending') and created_at < now() - interval '12 hours';
  update mandates set priority = 'critical'
   where priority = 'low'    and status in ('draft','drop_pending') and created_at < now() - interval '24 hours';
end;
$function$;

-- 6. Données : new -> drop_pending
update public.mandates set status = 'drop_pending' where status = 'new';

-- 7. Suspension automatique
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
        select id from public.mandates m
        where (m.status = 'assigned' and m.started_at is null and m.assigned_at is not null
               and now() > case
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

select cron.schedule('auto-suspend-mandates', '*/5 * * * *', $$select public.auto_suspend_overdue_mandates()$$);
