-- PLOMI — Notifications des gestionnaires : chaque fait et geste sur un mandat de leur organisation.
-- Source unique : activity_logs (toutes les transitions passent par transition_mandate_status),
-- plus la création d'un mandat (mandates) et la suspension d'un expert (experts).
-- Le gestionnaire auteur de l'action n'est pas notifié de sa propre action.

-- 1. Abandon par l'expert : le mandat retourne en liste de drop (et non plus « en pause »)
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.transition_mandate_status(uuid, mandate_status, uuid, text, assignment_type, uuid[])'::regprocedure);
  if position('when ''in_progress''    then array[''waiting_report'',''redrop'',''suspended'',''closed'']' in d) = 0 then
    raise exception 'ancre in_progress introuvable';
  end if;
  d := replace(d, 'when ''in_progress''    then array[''waiting_report'',''redrop'',''suspended'',''closed'']',
                  'when ''in_progress''    then array[''waiting_report'',''redrop'',''drop_pending'',''suspended'',''closed'']');
  execute d;
end $mig$;

CREATE OR REPLACE FUNCTION public.expert_abandon_mandate(p_mandate_id uuid, p_motif text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if nullif(trim(coalesce(p_motif,'')), '') is null then raise exception 'Le motif d''abandon est obligatoire'; end if;
  select * into v_m from public.mandates where id = p_mandate_id for update;
  if not found then raise exception 'Mandat introuvable'; end if;
  if v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
  if v_m.status not in ('assigned','in_progress') then
    raise exception 'Ce mandat ne peut plus être abandonné (statut actuel : %)', v_m.status;
  end if;
  -- l'attribution est marquée refusée AVANT le retour en liste de drop (qui annule les attributions actives)
  update public.mandate_assignments set status = 'refused', refused_at = now(), comment = trim(p_motif)
   where mandate_id = p_mandate_id and expert_id = v_expert and status in ('pending','accepted');
  perform public.transition_mandate_status(p_mandate_id, 'drop_pending', null, 'Abandon expert : ' || trim(p_motif));
  insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
  values (v_expert, 'mandate_refused', p_mandate_id, jsonb_build_object('motif', trim(p_motif), 'from_status', v_m.status)),
         (v_expert, 'redrop_caused', p_mandate_id, jsonb_build_object('reason', 'abandon'));
end; $function$;

-- 2. Envoi à tous les gestionnaires d'une organisation (sauf l'auteur)
create or replace function public.notify_managers(p_org uuid, p_type notification_type, p_title text, p_body text,
                                                  p_mandate_id uuid default null, p_entity_type text default null,
                                                  p_entity_id uuid default null, p_target public.notification_target_type default null,
                                                  p_exclude uuid default null)
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.notifications (user_id, mandate_id, type, title, body, channel, entity_type, entity_id, target_type)
  select up.id, p_mandate_id, p_type, p_title, p_body, 'in_app', p_entity_type, p_entity_id, p_target
    from public.user_profiles up
   where up.organization_id = p_org and up.role::text = 'gestionnaire_assurance'
     and up.id is distinct from p_exclude;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.notify_managers(uuid, notification_type, text, text, uuid, text, uuid, public.notification_target_type, uuid) from public, anon, authenticated;

-- Nom lisible d'un expert
create or replace function public.expert_display_name(p_expert uuid)
 returns text language sql stable security definer set search_path to 'public'
as $$ select coalesce(nullif(trim(concat_ws(' ', first_name, last_name)), ''), company_name, 'un expert') from public.experts where id = p_expert $$;

-- 3. Transitions de statut
create or replace function public.trg_notify_status_transition()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare
  m        public.mandates%rowtype;
  v_old    text := new.old_values_json->>'status';
  v_new    text := new.new_values_json->>'status';
  v_by     uuid := nullif(new.new_values_json->>'by', '')::uuid;
  v_motif  text := nullif(new.new_values_json->>'motif', '');
  v_by_expert boolean;
  v_who    text;
  v_exp    text;
  v_title  text;
  v_body   text;
  v_type   notification_type := 'status_change';
begin
  if new.action <> 'status_transition' or new.entity_type::text <> 'mandate' then return new; end if;
  select * into m from public.mandates where id = new.entity_id;
  if not found then return new; end if;

  v_by_expert := v_by is not null and exists (select 1 from public.experts where user_id = v_by);
  v_who := case when v_by is null then 'PLOMI (automatique)'
                when v_by_expert then (select public.expert_display_name(id) from public.experts where user_id = v_by limit 1)
                else public.lock_holder_name(v_by) end;
  v_exp := public.expert_display_name(coalesce(nullif(new.new_values_json->>'expert_id','')::uuid, m.assigned_expert_id));

  if v_new = 'assigned' then
    v_type := 'new_assignment';
    if v_by_expert then
      v_title := m.reference || ' pris en charge';
      v_body  := v_exp || ' a pris le mandat' || coalesce(' (' || m.city || ')', '') ||
                 case when m.selected_slot_at is not null then ', RDV le ' || to_char(m.selected_slot_at at time zone 'Europe/Paris', 'DD/MM à HH24:MI') else '' end || '.';
    else
      v_title := m.reference || ' attribué';
      v_body  := 'Attribué à ' || v_exp || ' par ' || v_who || '.';
    end if;
  elsif v_new = 'in_progress' then
    v_title := m.reference || ' : rapport commencé';
    v_body  := v_exp || ' a démarré l''intervention' || coalesce(' (' || m.city || ')', '') || '.';
  elsif v_new = 'waiting_report' then
    v_type  := 'new_report';
    v_title := m.reference || ' : rapport terminé';
    v_body  := v_exp || ' a envoyé son rapport. Le mandat est en attente de validation.';
  elsif v_new in ('redrop') or (v_new = 'dropped' and v_old = 'suspended') then
    v_title := m.reference || ' redroppé';
    v_body  := 'Redrop par ' || v_who || coalesce(' — ' || v_motif, '') || '.';
  elsif v_new = 'cancelled' then
    v_title := m.reference || ' supprimé';
    v_body  := 'Supprimé par ' || v_who || coalesce(' — ' || v_motif, '') || '.';
  elsif v_new = 'suspended' then
    v_title := m.reference || ' mis en pause';
    v_body  := 'Mis en pause par ' || v_who || coalesce(' — ' || v_motif, '') || '.';
  elsif v_new = 'drop_pending' and v_old in ('assigned','in_progress') then
    v_title := m.reference || ' retiré à ' || v_exp;
    v_body  := coalesce(v_motif, 'Retour en liste de drop') || '.';
  elsif v_new = 'closed' then
    v_title := m.reference || case when m.closure_type = 'without_follow_up' then ' clôturé sans suite' else ' clôturé' end;
    v_body  := 'Par ' || v_who || coalesce(' — ' || v_motif, '') || '.';
  else
    return new;   -- autres transitions (drop, retour en liste…) : pas de notification
  end if;

  perform public.notify_managers(m.insurance_org_id, v_type, v_title, v_body, m.id, 'mandate', m.id, 'mandate_details',
                                 case when v_by_expert then null else v_by end);
  return new;
end $$;

drop trigger if exists notify_status_transition on public.activity_logs;
create trigger notify_status_transition after insert on public.activity_logs
  for each row execute function public.trg_notify_status_transition();

-- 4. Création d'un mandat
create or replace function public.trg_notify_mandate_created()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  perform public.notify_managers(new.insurance_org_id, 'status_change',
            coalesce(new.reference, 'Nouveau mandat') || ' créé',
            'Créé par ' || coalesce(public.lock_holder_name(coalesce(new.created_by_user_id, auth.uid())), 'import automatique')
              || coalesce(' — ' || new.city, '') || coalesce(' · ' || upper(new.mandate_type::text), '') || '.',
            new.id, 'mandate', new.id, 'mandate_details', coalesce(new.created_by_user_id, auth.uid()));
  return new;
end $$;
drop trigger if exists notify_mandate_created on public.mandates;
create trigger notify_mandate_created after insert on public.mandates
  for each row execute function public.trg_notify_mandate_created();

-- 5. Suspension d'un expert (toutes les organisations qui travaillent avec lui)
create or replace function public.trg_notify_expert_suspended()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare r record;
begin
  if new.status_experts = 'suspendu' and old.status_experts is distinct from 'suspendu' then
    for r in select organization_id from public.org_experts where expert_id = new.id loop
      perform public.notify_managers(r.organization_id, 'system',
                public.expert_display_name(new.id) || ' suspendu',
                coalesce(new.suspension_reason, 'Suspension') || '. Il ne voit plus la carte jusqu''à la levée de la suspension.',
                null, 'expert', new.id, 'expert_details', new.suspended_by);
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists notify_expert_suspended on public.experts;
create trigger notify_expert_suspended after update of status_experts on public.experts
  for each row execute function public.trg_notify_expert_suspended();

revoke execute on function public.trg_notify_status_transition() from public, anon, authenticated;
revoke execute on function public.trg_notify_mandate_created() from public, anon, authenticated;
revoke execute on function public.trg_notify_expert_suspended() from public, anon, authenticated;

-- 6. Temps réel : la cloche se met à jour sans recharger (RLS « read own notifications » s'applique)
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- 7. Correctifs (appliqués après tests)
-- 7a. Nom de l'expert même quand le mandat vient de lui être retiré (dernière attribution)
do $mig$
declare d text; a text := 'v_exp := public.expert_display_name(coalesce(nullif(new.new_values_json->>''expert_id'','''')::uuid, m.assigned_expert_id));';
begin
  d := pg_get_functiondef('public.trg_notify_status_transition()'::regprocedure);
  if position(a in d) = 0 then raise exception 'ancre introuvable'; end if;
  d := replace(d, a, 'v_exp := coalesce(public.expert_display_name(coalesce(nullif(new.new_values_json->>''expert_id'','''')::uuid, m.assigned_expert_id,
              (select ma.expert_id from public.mandate_assignments ma where ma.mandate_id = m.id order by ma.assigned_at desc limit 1))), ''l''''expert'');');
  execute d;
end $mig$;
-- 7b. Une action n'est « de l'expert » que si son auteur est l'expert du mandat (un gestionnaire peut aussi avoir un profil expert)
do $mig$
declare d text; a text := 'v_by_expert := v_by is not null and exists (select 1 from public.experts where user_id = v_by);';
begin
  d := pg_get_functiondef('public.trg_notify_status_transition()'::regprocedure);
  if position(a in d) = 0 then raise exception 'ancre introuvable'; end if;
  d := replace(d, a, 'v_by_expert := v_by is not null and not public.is_manager() and exists (
                   select 1 from public.experts x where x.user_id = v_by
                      and x.id in (coalesce(nullif(new.new_values_json->>''expert_id'','''')::uuid, m.assigned_expert_id),
                                   (select ma.expert_id from public.mandate_assignments ma where ma.mandate_id = m.id order by ma.assigned_at desc limit 1)));');
  execute d;
end $mig$;
