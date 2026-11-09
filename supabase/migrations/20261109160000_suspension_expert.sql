-- PLOMI — Suspension des EXPERTS (et non plus des mandats) en cas de délai non tenu.
-- Règles métier (validées avec le mandataire) :
--  * Suspension automatique de l'expert si un mandat attribué n'est pas démarré :
--      - créneau choisi + 30 min (créneau non honoré),
--      - mandat pris sur la carte sans créneau : fin de journée (heure de Paris).
--    Le mandat retourne en liste de drop (le gestionnaire décide de la suite).
--  * Le gestionnaire peut suspendre un expert à tout moment (motif obligatoire).
--  * La suspension d'un expert est levée uniquement à la main par le gestionnaire.
--  * Un expert suspendu ne voit plus la carte et ne peut pas recevoir / prendre de mandat.
--  * 48 h (attribution manuelle non démarrée) et 2 h (intervention en cours) : simples indicateurs
--    du tableau de bord, aucune action automatique.
--  * Le statut « suspended » d'un MANDAT reste une mise en pause du dossier, indépendante de l'expert.

alter table public.experts
  add column if not exists suspended_at timestamptz,
  add column if not exists suspension_reason text,
  add column if not exists suspended_by uuid,
  add column if not exists status_before_suspension public.expert_status;

-- Cœur commun (cron + gestionnaire)
create or replace function public.expert_suspend_internal(p_expert_id uuid, p_reason text, p_by uuid default null, p_mandate_id uuid default null)
 returns void language plpgsql security definer set search_path to 'public'
as $$
begin
  update public.experts
     set status_before_suspension = case when status_experts = 'suspendu' then status_before_suspension else status_experts end,
         status_experts = 'suspendu', suspended_at = now(), suspension_reason = p_reason, suspended_by = p_by
   where id = p_expert_id;

  -- Le mandat concerné (attribué, non démarré) retourne en liste de drop
  if p_mandate_id is not null and exists (select 1 from public.mandates where id = p_mandate_id and status = 'assigned') then
    update public.mandate_assignments
       set status = 'expired', comment = coalesce(comment, p_reason)
     where mandate_id = p_mandate_id and expert_id = p_expert_id and status in ('pending','accepted');
    perform public.transition_mandate_status(p_mandate_id, 'drop_pending', null, 'Expert suspendu : ' || p_reason);
  end if;

  insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
  values (p_expert_id, 'expert_suspended', p_mandate_id, jsonb_build_object('reason', p_reason, 'by', p_by));
end $$;
revoke execute on function public.expert_suspend_internal(uuid, text, uuid, uuid) from public, anon, authenticated;

-- Gestionnaire : suspendre un expert de son organisation
create or replace function public.suspend_expert(p_expert_id uuid, p_motif text, p_mandate_id uuid default null)
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id(); r record; n integer := 0;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if nullif(trim(coalesce(p_motif, '')), '') is null then raise exception 'Motif obligatoire pour suspendre un expert'; end if;
  if not exists (select 1 from public.org_experts where organization_id = v_org and expert_id = p_expert_id) then
    raise exception 'Expert hors de votre organisation';
  end if;

  perform public.expert_suspend_internal(p_expert_id, trim(p_motif), auth.uid(), p_mandate_id);

  -- Ses autres mandats attribués mais non démarrés (de l'organisation) retournent aussi en liste de drop
  for r in select id from public.mandates
            where assigned_expert_id = p_expert_id and insurance_org_id = v_org and status = 'assigned'
              and id is distinct from p_mandate_id loop
    update public.mandate_assignments set status = 'cancelled', cancelled_at = now(), comment = coalesce(comment, 'Expert suspendu')
     where mandate_id = r.id and expert_id = p_expert_id and status in ('pending','accepted');
    perform public.transition_mandate_status(r.id, 'drop_pending', null, 'Expert suspendu : ' || trim(p_motif));
    n := n + 1;
  end loop;
  return n + case when p_mandate_id is null then 0 else 1 end;
end $$;

-- Gestionnaire : lever la suspension (l'expert retrouve la carte, aucun mandat ne lui est rendu)
create or replace function public.lift_expert_suspension(p_expert_id uuid, p_motif text default null)
 returns void language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if not exists (select 1 from public.org_experts where organization_id = v_org and expert_id = p_expert_id) then
    raise exception 'Expert hors de votre organisation';
  end if;
  update public.experts
     set status_experts = coalesce(nullif(status_before_suspension, 'suspendu'), 'deconnecte'),
         status_before_suspension = null, suspended_at = null, suspension_reason = null, suspended_by = null
   where id = p_expert_id and status_experts = 'suspendu';
  if not found then raise exception 'Cet expert n''est pas suspendu'; end if;
  insert into public.expert_performance_logs (expert_id, event_type, metadata)
  values (p_expert_id, 'expert_reinstated', jsonb_build_object('by', auth.uid(), 'motif', p_motif));
end $$;

revoke execute on function public.suspend_expert(uuid, text, uuid) from public, anon;
revoke execute on function public.lift_expert_suspension(uuid, text) from public, anon;
grant execute on function public.suspend_expert(uuid, text, uuid) to authenticated;
grant execute on function public.lift_expert_suspension(uuid, text) to authenticated;

-- Un expert suspendu ne peut pas recevoir / prendre de mandat
do $mig$
declare d text; a text := 'if p_new_status = ''assigned'' and p_expert_id is null then';
begin
  d := pg_get_functiondef('public.transition_mandate_status(uuid, mandate_status, uuid, text, assignment_type, uuid[])'::regprocedure);
  if position(a in d) = 0 then raise exception 'ancre introuvable dans transition_mandate_status'; end if;
  d := replace(d, a,
    'if p_new_status = ''assigned'' and exists (select 1 from public.experts where id = p_expert_id and status_experts = ''suspendu'') then
        raise exception ''Expert suspendu : il ne peut pas recevoir de mandat tant que sa suspension n''''est pas levée'';
    end if;

    ' || a);
  execute d;
end $mig$;

-- La carte de l'expert est vide tant qu'il est suspendu
do $mig$
declare d text; a text := 'WHERE ((visible_on_map = true)';
begin
  d := pg_get_viewdef('public.available_mandates_for_expert'::regclass);
  if position(a in d) = 0 then raise exception 'ancre introuvable dans available_mandates_for_expert'; end if;
  d := replace(d, a, 'WHERE (NOT (EXISTS ( SELECT 1 FROM experts e WHERE e.user_id = auth.uid() AND e.status_experts = ''suspendu''::expert_status))) AND ((visible_on_map = true)');
  execute 'create or replace view public.available_mandates_for_expert as ' || d;
end $mig$;

-- Tâche planifiée (toutes les 5 min) : suspension de l'EXPERT, plus du mandat
create or replace function public.auto_suspend_overdue_mandates()
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare r record; n integer := 0;
begin
  for r in
    select m.id, m.assigned_expert_id, m.selected_slot_at
      from public.mandates m
      left join lateral (
        select a.assignment_type from public.mandate_assignments a
         where a.mandate_id = m.id and a.status in ('pending','accepted')
         order by a.assigned_at desc limit 1) a on true
     where m.status = 'assigned' and m.started_at is null and m.assigned_at is not null
       and m.assigned_expert_id is not null
       and coalesce(a.assignment_type::text, '') <> 'manual'      -- 48 h manuel = indicateur seulement
       and now() > case
             when m.selected_slot_at is not null then m.selected_slot_at + interval '30 minutes'
             else (date_trunc('day', m.assigned_at at time zone 'Europe/Paris') + interval '1 day') at time zone 'Europe/Paris'
           end
  loop
    perform public.expert_suspend_internal(
      r.assigned_expert_id,
      case when r.selected_slot_at is not null then 'Créneau non honoré (non démarré 30 min après le créneau)'
           else 'Mandat pris sur la carte et non démarré dans la journée' end,
      null, r.id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Lever la pause d'un mandat : attribution remise en « manuelle » (48 h indicatif, pas de suspension auto à minuit)
do $mig$
declare d text; a text := 'coalesce(nullif(p_motif, ''''), ''Suspension levée''), coalesce(v_type, ''manual''));';
begin
  d := pg_get_functiondef('public.resume_mandate(uuid, text, text)'::regprocedure);
  if position(a in d) = 0 then raise exception 'ancre introuvable dans resume_mandate'; end if;
  d := replace(d, a, 'coalesce(nullif(p_motif, ''''), ''Suspension levée''), ''manual'');');
  execute d;
end $mig$;

-- Nouveaux événements de performance
alter table public.expert_performance_logs drop constraint expert_performance_logs_event_type_check;
alter table public.expert_performance_logs add constraint expert_performance_logs_event_type_check
  check (event_type = any (array['mandate_assigned','mandate_accepted','mandate_refused','mandate_expired','mandate_completed',
    'redrop_caused','intervention_started','intervention_completed','report_submitted','report_validated','report_rejected',
    'arrived_on_site','expert_suspended','expert_reinstated']::text[]));
