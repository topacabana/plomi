-- PLOMI — Tableau de bord gestionnaire : un seul appel, restreint à l'organisation du gestionnaire.
-- Renvoie : compteurs par statut, activité du jour, urgences (règles métier), planning du jour,
-- rapports à valider, KPI 30 j (avec période précédente), experts, verrous, tendance 14 j.

create or replace function public.manager_dashboard()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $$
declare
  v_org   uuid := public.current_user_organization_id();
  v_now   timestamptz := now();
  v_today date := (now() at time zone 'Europe/Paris')::date;
  v_d0    timestamptz := (v_today::timestamp) at time zone 'Europe/Paris';   -- minuit (Paris)
  v_res   jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;

  with m as (
    select m.*, coalesce(nullif(trim(concat_ws(' ', e.first_name, e.last_name)), ''), e.company_name) as expert_name
      from public.mandates m
      left join public.experts e on e.id = m.assigned_expert_id
     where m.insurance_org_id = v_org
  ),
  -- Dernière attribution active (pour la règle de suspension automatique)
  a as (
    select distinct on (ma.mandate_id) ma.mandate_id, ma.assignment_type
      from public.mandate_assignments ma join m on m.id = ma.mandate_id
     where ma.status in ('pending','accepted')
     order by ma.mandate_id, ma.assigned_at desc
  ),
  -- Entrée en statut courant (historique), à défaut dates du mandat
  since as (
    select m.id, coalesce((select max(h.created_at) from public.mandate_history h
                            where h.mandate_id = m.id and h.status_to = m.status::text), m.updated_at) as at
      from m where m.status in ('suspended','waiting_report','redrop')
  ),
  urg as (
    -- 1. Attribué, pas démarré : suspension automatique imminente
    select m.id, m.reference, m.status::text status, m.city, m.priority::text priority, m.expert_name,
           case when d.deadline <= v_now + interval '30 minutes' then 1 else 2 end sev,
           'Suspension automatique ' || case when d.deadline <= v_now then 'imminente'
                                             else 'dans ' || public.dashboard_duration(d.deadline - v_now) end
             || ' : intervention non démarrée' as reason,
           d.deadline as due_at, 'suspension_imminente' as category
      from m left join a on a.mandate_id = m.id
      cross join lateral (select case
                when a.assignment_type = 'manual' then m.assigned_at + interval '48 hours'
                when m.selected_slot_at is not null then m.selected_slot_at + interval '30 minutes'
                else ((date_trunc('day', m.assigned_at at time zone 'Europe/Paris') + interval '1 day') at time zone 'Europe/Paris')
              end as deadline) d
     where m.status = 'assigned' and m.started_at is null and m.assigned_at is not null
       and d.deadline <= v_now + interval '2 hours'
    union all
    -- 2. En cours depuis plus de 1 h 30 (suspension à 2 h)
    select m.id, m.reference, m.status::text, m.city, m.priority::text, m.expert_name,
           case when m.started_at <= v_now - interval '1 hour 50 minutes' then 1 else 2 end,
           'En cours depuis ' || public.dashboard_duration(v_now - m.started_at) || ' : suspension automatique à 2 h',
           m.started_at + interval '2 hours', 'intervention_longue'
      from m where m.status = 'in_progress' and m.started_at <= v_now - interval '90 minutes'
    union all
    -- 3. Critique sur la carte sans preneur
    select m.id, m.reference, m.status::text, m.city, m.priority::text, null,
           1, 'Priorité critique sans preneur depuis ' || public.dashboard_duration(v_now - m.drop_at), null, 'critique_sans_preneur'
      from m where m.status in ('dropped','redrop') and m.priority = 'critical'
       and m.drop_at is not null and m.drop_at <= v_now - interval '1 hour'
    union all
    -- 4. Diffusé depuis plus de 24 h sans preneur (hors critique déjà signalé)
    select m.id, m.reference, m.status::text, m.city, m.priority::text, null,
           3, 'Sur la carte sans preneur depuis ' || public.dashboard_duration(v_now - m.drop_at), null, 'sans_preneur'
      from m where m.status in ('dropped','redrop') and m.priority <> 'critical'
       and m.drop_at <= v_now - interval '24 hours'
    union all
    -- 5. Suspendu depuis plus de 24 h
    select m.id, m.reference, m.status::text, m.city, m.priority::text, m.expert_name,
           2, 'Suspendu depuis ' || public.dashboard_duration(v_now - s.at) || ' sans reprise', null, 'suspendu'
      from m join since s on s.id = m.id
     where m.status = 'suspended' and s.at <= v_now - interval '24 hours'
    union all
    -- 6. Rapport en attente de validation
    select m.id, m.reference, m.status::text, m.city, m.priority::text, m.expert_name,
           case when s.at <= v_now - interval '48 hours' then 2 else 3 end,
           'Rapport à valider depuis ' || public.dashboard_duration(v_now - s.at), null, 'rapport'
      from m join since s on s.id = m.id
     where m.status = 'waiting_report' and s.at <= v_now - interval '24 hours'
    union all
    -- 7. Échéance dépassée ou dans les 24 h
    select m.id, m.reference, m.status::text, m.city, m.priority::text, m.expert_name,
           case when m.expiry_at <= v_now then 1 else 2 end,
           case when m.expiry_at <= v_now then 'Échéance dépassée depuis ' || public.dashboard_duration(v_now - m.expiry_at)
                else 'Échéance dans ' || public.dashboard_duration(m.expiry_at - v_now) end,
           m.expiry_at, 'echeance'
      from m where m.expiry_at is not null and m.expiry_at <= v_now + interval '24 hours'
       and m.status not in ('closed','cancelled','waiting_report')
    union all
    -- 8. En liste de drop depuis plus de 24 h
    select m.id, m.reference, m.status::text, m.city, m.priority::text, null,
           3, 'En liste de drop depuis ' || public.dashboard_duration(v_now - m.created_at), null, 'liste_drop'
      from m where m.status in ('draft','new','drop_pending') and m.created_at <= v_now - interval '24 hours'
    union all
    -- 9. Adresse non localisée (invisible sur les cartes)
    select m.id, m.reference, m.status::text, m.city, m.priority::text, null,
           3, 'Adresse non localisée : ' || coalesce(m.geocode_error, 'coordonnées manquantes'), null, 'adresse'
      from m where m.latitude is null and m.status not in ('closed','cancelled')
  ),
  u as (select distinct on (id, reason) * from urg)
  select jsonb_build_object(
    'generated_at', v_now,
    'counts', (select jsonb_build_object(
        'drop_list',      count(*) filter (where status in ('draft','new','drop_pending')),
        'on_map',         count(*) filter (where status = 'dropped'),
        'redrop',         count(*) filter (where status = 'redrop'),
        'assigned',       count(*) filter (where status = 'assigned'),
        'in_progress',    count(*) filter (where status = 'in_progress'),
        'waiting_report', count(*) filter (where status = 'waiting_report'),
        'suspended',      count(*) filter (where status = 'suspended'),
        'active_total',   count(*) filter (where status not in ('closed','cancelled'))) from m),
    'today', (select jsonb_build_object(
        'created',  count(*) filter (where created_at >= v_d0),
        'dropped',  count(*) filter (where drop_at >= v_d0),
        'assigned', count(*) filter (where assigned_at >= v_d0),
        'closed',   count(*) filter (where closed_at >= v_d0 and coalesce(closure_type,'completed') = 'completed'),
        'planned',  count(*) filter (where coalesce(selected_slot_at, slot_1_at) >= v_d0
                                       and coalesce(selected_slot_at, slot_1_at) < v_d0 + interval '1 day'
                                       and status not in ('closed','cancelled'))) from m),
    'urgency_summary', (select jsonb_build_object(
        'total', count(*), 'critical', count(*) filter (where sev = 1), 'high', count(*) filter (where sev = 2),
        'medium', count(*) filter (where sev = 3),
        'by_category', coalesce((select jsonb_object_agg(category, n) from (select category, count(*) n from u group by category) c), '{}'::jsonb)) from u),
    -- 80 urgences au plus, les plus graves d'abord (le résumé donne les totaux)
    'urgencies', coalesce((select jsonb_agg(x order by x.sev, x.due_at nulls last, x.reference) from (
        select * from u order by sev, due_at nulls last, reference limit 80) x), '[]'::jsonb),
    'planning', coalesce((select jsonb_agg(jsonb_build_object(
          'id', id, 'reference', reference, 'slot_at', coalesce(selected_slot_at, slot_1_at),
          'status', status, 'city', city, 'expert_name', expert_name, 'arrived_at', arrived_at,
          'late', arrived_at is null and coalesce(selected_slot_at, slot_1_at) < v_now - interval '15 minutes'
                  and status in ('assigned'))
          order by coalesce(selected_slot_at, slot_1_at))
        from m where coalesce(selected_slot_at, slot_1_at) >= v_d0
                 and coalesce(selected_slot_at, slot_1_at) < v_d0 + interval '1 day'
                 and status not in ('closed','cancelled')), '[]'::jsonb),
    'reports_to_validate', coalesce((select jsonb_agg(jsonb_build_object(
          'id', m.id, 'reference', m.reference, 'expert_name', m.expert_name, 'city', m.city,
          'since', s.at) order by s.at)
        from m join since s on s.id = m.id where m.status = 'waiting_report'), '[]'::jsonb),
    'kpi', (select jsonb_build_object(
        'drop_delay_h',     round(avg(extract(epoch from drop_at - created_at) / 3600) filter (where created_at >= v_now - interval '30 days' and drop_at is not null)::numeric, 1),
        'drop_delay_h_prev',round(avg(extract(epoch from drop_at - created_at) / 3600) filter (where created_at >= v_now - interval '60 days' and created_at < v_now - interval '30 days' and drop_at is not null)::numeric, 1),
        'assign_delay_h',     round(avg(extract(epoch from assigned_at - drop_at) / 3600) filter (where assigned_at >= v_now - interval '30 days' and drop_at is not null and assigned_at > drop_at)::numeric, 1),
        'assign_delay_h_prev',round(avg(extract(epoch from assigned_at - drop_at) / 3600) filter (where assigned_at >= v_now - interval '60 days' and assigned_at < v_now - interval '30 days' and drop_at is not null and assigned_at > drop_at)::numeric, 1),
        'processing_h',     round(avg(extract(epoch from closed_at - assigned_at) / 3600) filter (where closed_at >= v_now - interval '30 days' and assigned_at is not null and coalesce(closure_type,'completed') = 'completed')::numeric, 1),
        'processing_h_prev',round(avg(extract(epoch from closed_at - assigned_at) / 3600) filter (where closed_at >= v_now - interval '60 days' and closed_at < v_now - interval '30 days' and assigned_at is not null and coalesce(closure_type,'completed') = 'completed')::numeric, 1),
        'closed_30d',       count(*) filter (where closed_at >= v_now - interval '30 days' and coalesce(closure_type,'completed') = 'completed'),
        'closed_30d_prev',  count(*) filter (where closed_at >= v_now - interval '60 days' and closed_at < v_now - interval '30 days' and coalesce(closure_type,'completed') = 'completed'),
        'without_follow_up_30d', count(*) filter (where closed_at >= v_now - interval '30 days' and closure_type = 'without_follow_up'),
        'created_30d',      count(*) filter (where created_at >= v_now - interval '30 days'),
        'created_30d_prev', count(*) filter (where created_at >= v_now - interval '60 days' and created_at < v_now - interval '30 days'),
        'redrop_rate',      round(100.0 * count(*) filter (where drop_at >= v_now - interval '30 days' and redrop_count > 0)
                                   / nullif(count(*) filter (where drop_at >= v_now - interval '30 days'), 0)),
        'suspensions_30d',  (select count(*) from public.mandate_history h join m mm on mm.id = h.mandate_id
                              where h.status_to = 'suspended' and h.created_at >= v_now - interval '30 days'),
        'report_validation_rate', (select round(100.0 * count(*) filter (where r.status in ('validated','completed') or (r.status = 'submitted' and mm.status = 'closed'))
                                               / nullif(count(*) filter (where r.status in ('submitted','completed','validated')), 0))
                                     from public.rdf_reports r join m mm on mm.id = r.mandate_id
                                    where r.submitted_at >= v_now - interval '30 days')) from m),
    'experts', (select jsonb_build_object(
        'total',      count(distinct e.id),
        'connected',  count(distinct e.id) filter (where e.status_experts = 'connecte'),
        'active_7d',  (select count(distinct ma.expert_id) from public.mandate_assignments ma join m on m.id = ma.mandate_id
                        where ma.assigned_at >= v_now - interval '7 days'),
        'busy',       (select count(distinct assigned_expert_id) from m where status in ('assigned','in_progress')),
        'top', coalesce((select jsonb_agg(t order by t.closed desc, t.name) from (
                  select coalesce(nullif(trim(concat_ws(' ', x.first_name, x.last_name)), ''), x.company_name) as name,
                         count(*) as closed, round(x.rating::numeric, 1) as rating
                    from m join public.experts x on x.id = m.assigned_expert_id
                   where m.closed_at >= v_now - interval '30 days' and coalesce(m.closure_type,'completed') = 'completed'
                   group by x.id, x.first_name, x.last_name, x.company_name, x.rating
                   order by count(*) desc limit 5) t), '[]'::jsonb))
        from public.org_experts oe join public.experts e on e.id = oe.expert_id where oe.organization_id = v_org),
    'locks', (select jsonb_build_object('active', count(*), 'mine', count(*) filter (where l.user_id = auth.uid()))
                from public.mandate_locks l join m on m.id = l.mandate_id where l.expires_at > v_now),
    'trend', (select jsonb_agg(jsonb_build_object(
          'day', d::date,
          'created', (select count(*) from m where created_at >= (d::timestamp at time zone 'Europe/Paris') and created_at < ((d + interval '1 day')::timestamp at time zone 'Europe/Paris')),
          'closed',  (select count(*) from m where closed_at  >= (d::timestamp at time zone 'Europe/Paris') and closed_at  < ((d + interval '1 day')::timestamp at time zone 'Europe/Paris')
                                                and coalesce(closure_type,'completed') = 'completed'))
          order by d)
        from generate_series(v_today - 13, v_today, interval '1 day') d)
  ) into v_res;

  return v_res;
end $$;

-- Durée lisible : « 3 j 4 h », « 5 h 12 min », « 18 min »
create or replace function public.dashboard_duration(p interval)
 returns text language sql immutable set search_path to 'public'
as $$
  select case
    when p is null then ''
    when p >= interval '1 day'  then extract(day from p)::int || ' j' || case when extract(hour from p)::int > 0 then ' ' || extract(hour from p)::int || ' h' else '' end
    when p >= interval '1 hour' then extract(hour from p)::int || ' h ' || lpad(extract(minute from p)::int::text, 2, '0')
    else greatest(extract(minute from p)::int, 0) || ' min' end
$$;

revoke execute on function public.manager_dashboard() from public, anon;
grant execute on function public.manager_dashboard() to authenticated;
