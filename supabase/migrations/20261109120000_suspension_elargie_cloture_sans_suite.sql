-- PLOMI — Suspension élargie et clôture sans suite
-- 1. La suspension est possible dès la liste de drop (drop_pending, dropped, redrop) en plus de assigned / in_progress.
--    Un mandat suspendu peut revenir en liste de drop.
-- 2. Clôture « sans suite » (ex. le client renonce à son assurance) : possible depuis tout statut avant rapport,
--    motif obligatoire, marquée closure_type = 'without_follow_up' et exclue des KPI de clôture / de traitement.

alter table public.mandates add column if not exists closure_type text
  check (closure_type in ('completed', 'without_follow_up'));
update public.mandates set closure_type = 'completed' where status = 'closed' and closure_type is null;

CREATE OR REPLACE FUNCTION public.transition_mandate_status(p_mandate_id uuid, p_new_status mandate_status, p_expert_id uuid DEFAULT NULL::uuid, p_motif text DEFAULT NULL::text, p_assignment_type assignment_type DEFAULT 'manual'::assignment_type, p_list_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_current  mandate_status;
    v_expert   uuid;
    v_allowed  mandate_status[];
    v_sans_suite boolean := false;
begin
    select status, assigned_expert_id into v_current, v_expert
    from public.mandates where id = p_mandate_id for update;
    if not found then
        raise exception 'Mandat introuvable : %', p_mandate_id;
    end if;

    -- Un mandat déjà diffusé une fois (drop_at renseigné) revient sur la carte en redrop
    if p_new_status = 'dropped' and v_current = 'drop_pending'
       and exists (select 1 from public.mandates where id = p_mandate_id and drop_at is not null) then
        p_new_status := 'redrop';
    end if;

    -- Verrou gestionnaire (F17) : l'expert attribué / qui prend le mandat n'est jamais bloqué
    if public.is_manager()
       and not (public.current_expert_id() is not null
                and public.current_expert_id() in (coalesce(v_expert, '00000000-0000-0000-0000-000000000000'::uuid),
                                                  coalesce(p_expert_id, '00000000-0000-0000-0000-000000000000'::uuid))) then
        if exists (select 1 from public.mandate_locks
                    where mandate_id = p_mandate_id and user_id <> auth.uid() and expires_at > now()) then
            raise exception 'Mandat % en cours de traitement par %',
                (select reference from public.mandates where id = p_mandate_id),
                (select public.lock_holder_name(user_id) from public.mandate_locks where mandate_id = p_mandate_id);
        end if;
        insert into public.mandate_locks (mandate_id, user_id, locked_at, expires_at)
        values (p_mandate_id, auth.uid(), now(), now() + interval '10 minutes')
        on conflict (mandate_id) do update set user_id = excluded.user_id, expires_at = excluded.expires_at;
    end if;

    v_allowed := case v_current
        when 'draft'          then array['drop_pending','cancelled','closed']::mandate_status[]
        when 'new'            then array['drop_pending','cancelled','closed']::mandate_status[]
        when 'drop_pending'   then array['dropped','redrop','assigned','suspended','cancelled','closed']::mandate_status[]
        when 'dropped'        then array['assigned','drop_pending','suspended','cancelled','closed']::mandate_status[]
        when 'redrop'         then array['assigned','drop_pending','suspended','cancelled','closed']::mandate_status[]
        when 'assigned'       then array['in_progress','drop_pending','redrop','suspended','cancelled','closed']::mandate_status[]
        when 'in_progress'    then array['waiting_report','redrop','suspended','closed']::mandate_status[]
        when 'waiting_report' then array['closed','redrop','assigned']::mandate_status[]
        when 'suspended'      then array['redrop','assigned','drop_pending','cancelled','closed']::mandate_status[]
        else                       array[]::mandate_status[]
    end;

    if not (p_new_status = any(v_allowed)) then
        raise exception 'Transition interdite : % → % (autorisées : %)', v_current, p_new_status, v_allowed;
    end if;

    -- Clôture avant rapport = clôture sans suite, motif obligatoire
    if p_new_status = 'closed' and v_current <> 'waiting_report' then
        if nullif(trim(coalesce(p_motif, '')), '') is null then
            raise exception 'Motif obligatoire pour une clôture sans suite';
        end if;
        v_sans_suite := true;
    end if;

    if p_new_status = 'assigned' and p_expert_id is null then
        raise exception 'Un expert est requis pour passer en assigned';
    end if;

    if p_list_ids is not null and cardinality(p_list_ids) > 0
       and p_new_status not in ('dropped','redrop') then
        raise exception 'Les listes ne s''utilisent qu''avec un drop ou un redrop';
    end if;

    update public.mandates set
        status = p_new_status,
        priority = case when p_new_status = 'redrop' then 'critical'::priority_level else priority end,
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
        closure_type = case
            when p_new_status = 'closed' then case when v_sans_suite then 'without_follow_up' else 'completed' end
            else closure_type end,
        motif_abandon = coalesce(nullif(p_motif, ''), motif_abandon),
        date_abandon  = case when nullif(p_motif, '') is not null then now() else date_abandon end,
        target_list_ids = case
            when p_new_status in ('dropped','redrop') then coalesce(p_list_ids, '{}')
            when p_new_status in ('drop_pending','cancelled') or v_sans_suite then '{}'
            else target_list_ids end
    where id = p_mandate_id;

    if p_new_status in ('drop_pending','redrop','cancelled','assigned') or v_sans_suite then
        update public.mandate_assignments
           set status = 'cancelled', cancelled_at = now(),
               comment = coalesce(comment, 'transition ' || case when v_sans_suite then 'cloture sans suite' else p_new_status::text end)
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
                               'closure_type', case when p_new_status = 'closed' then case when v_sans_suite then 'without_follow_up' else 'completed' end end,
                               'assignment_type', case when p_new_status = 'assigned' then p_assignment_type end,
                               'list_ids', p_list_ids));
end;
$function$;

-- Pas de « rapport validé » pour un expert si la clôture est sans suite
CREATE OR REPLACE FUNCTION public.trg_kpi_on_mandate_closed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_expert uuid;
begin
  for v_expert in
    select distinct e.id
    from public.rdf_reports r
    join public.experts e on e.user_id = r.created_by
    where r.mandate_id = new.id
  loop
    if new.status = 'closed' and coalesce(new.closure_type, 'completed') = 'completed' then
      insert into public.expert_performance_logs (expert_id, mandate_id, event_type, metadata)
      values (v_expert, new.id, 'report_validated',
              jsonb_build_object('validated_by', auth.uid()));
    end if;
    perform public.recalculate_expert_kpis(v_expert);
  end loop;
  return new;
end;
$function$;

-- KPI : les clôtures sans suite ne comptent ni comme clôtures ni dans les temps de traitement
do $mig$
declare d text; n int;
begin
  d := pg_get_functiondef('public.kpi_report(date, date, text, uuid[], text[])'::regprocedure);
  d := replace(d, 'm.drop_at, m.started_at, m.closed_at, m.status',
                  'm.drop_at, m.started_at, case when m.closure_type = ''without_follow_up'' then null else m.closed_at end as closed_at, m.status');
  d := replace(d, 'closed_at is not null and assigned_at is not null',
                  'closed_at is not null and assigned_at is not null and closure_type is distinct from ''without_follow_up''');
  d := replace(d, 'mm.closed_at >= t0 and mm.closed_at < t1)',
                  'mm.closed_at >= t0 and mm.closed_at < t1 and mm.closure_type is distinct from ''without_follow_up'')');
  n := (length(d) - length(replace(d, 'without_follow_up', ''))) / length('without_follow_up');
  if n <> 5 then raise exception 'kpi_report : % remplacements au lieu de 5', n; end if;
  execute d;
end $mig$;

-- Libellé
CREATE OR REPLACE FUNCTION public.mandate_closure_label(p_status text, p_closure_type text)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public'
AS $$ select case when p_status = 'closed' and p_closure_type = 'without_follow_up' then 'Clôturé sans suite'
                  else public.mandate_status_label(p_status) end $$;
