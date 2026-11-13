-- Tableau de bord : zone d'activité (zone de chalandise réelle) et couverture experts.
-- La couverture repose sur la zone déclarée dans le profil de l'expert (experts.coverage_zone),
-- ex. « Hauts-de-Seine 92 / Paris 75 », « Île-de-France (75-78-91-92-93-94-95) » : aucun calcul de distance.

-- Départements cités dans une zone de couverture saisie en texte libre.
-- « Île-de-France » sans liste entre parenthèses = ses 8 départements.
create or replace function public.coverage_zone_departments(p_zone text)
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct d order by d), '{}')
  from (
    select upper(m[1]) d
      from regexp_matches(coalesce(p_zone, ''), '(?<![0-9])(2[AaBb]|97[1-6]|[0-9]{2})(?![0-9])', 'g') m
    union all
    select unnest(array['75','77','78','91','92','93','94','95'])
     where p_zone ~* 'le[- ]de[- ]france' and p_zone !~* 'le[- ]de[- ]france\s*\('
  ) s
$$;

-- p_radius_km : conservé pour compatibilité, n'est plus utilisé (plus aucun calcul de distance).
create or replace function public.coverage_dashboard(p_radius_km int default 30)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_now timestamptz := now();
  v_res jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;

  with m as (   -- mandats de l'organisation (hors brouillons / annulés)
    select m.id, m.created_at, m.insurer_id,
           case when upper(left(m.postal_code, 2)) = '97' then left(m.postal_code, 3)
                when m.postal_code ~ '^20' then (case when m.postal_code < '20200' then '2A' else '2B' end)
                else nullif(left(regexp_replace(coalesce(m.postal_code, ''), '\s', '', 'g'), 2), '') end dep,
           lower(btrim(coalesce(m.city, ''))) || '|' || coalesce(m.postal_code, '') commune
      from mandates m
     where m.insurance_org_id = v_org and m.status::text not in ('draft', 'cancelled')
  ),
  ex as (       -- experts actifs (vivier) et départements de leur zone de couverture
    select e.id, public.coverage_zone_departments(e.coverage_zone) deps
      from experts e
     where coalesce(e.status_experts::text, '') <> 'suspendu' and coalesce(e.last_name, '') <> 'supprimé'
  ),
  cov as (select unnest(deps) dep, count(*) experts from ex group by 1),
  mc as (select m.*, coalesce(c.experts, 0) experts from m left join cov c using (dep)),
  dep_first as (select dep, min(created_at) first_at, count(*) n from m where dep is not null group by dep),
  months as (
    select generate_series(date_trunc('month', v_now) - interval '5 months', date_trunc('month', v_now), interval '1 month') mo
  ),
  ins as (
    select i.id, i.name, i.catchment_city, i.catchment_radius_km r, i.catchment_postal_code cpc
      from insurers i where i.organization_id = v_org and i.archived_at is null
  )
  select jsonb_build_object(
    'experts_active', (select count(*) from ex),
    'experts_without_zone', (select count(*) from ex where cardinality(deps) = 0),
    'mandates_total', (select count(*) from m),
    'departments', (select count(*) from dep_first),
    'departments_new_30d', (select count(*) from dep_first where first_at >= v_now - interval '30 days'),
    'communes', (select count(distinct commune) from m where commune <> '|'),
    'communes_new_30d', (select count(*) from (select commune, min(created_at) f from m where commune <> '|' group by commune) c where f >= v_now - interval '30 days'),
    'covered_departments', (select count(*) from cov),
    'coverage_pct', (select round(100.0 * count(*) filter (where experts > 0) / nullif(count(*), 0)) from mc where dep is not null),
    'coverage_pct_prev', (select round(100.0 * count(*) filter (where experts > 0) / nullif(count(*), 0)) from mc where dep is not null and created_at < v_now - interval '30 days'),
    'uncovered_mandates', (select count(*) from mc where dep is not null and experts = 0),
    'uncovered_departments', (select count(*) from dep_first d where not exists (select 1 from cov where cov.dep = d.dep)),
    'top_departments', coalesce((select jsonb_agg(jsonb_build_object('dep', d.dep, 'n', d.n, 'experts', coalesce(c.experts, 0),
                          'is_new', d.first_at >= v_now - interval '30 days') order by d.n desc, d.dep)
                        from (select * from dep_first order by n desc, dep limit 16) d left join cov c using (dep)), '[]'),
    -- Départements à renforcer : sans expert d'abord, puis le plus de mandats par expert
    'weak_departments', coalesce((select jsonb_agg(w order by (w->>'experts')::int, (w->>'per_expert')::numeric desc nulls first, (w->>'n')::int desc)
                        from (select jsonb_build_object('dep', d.dep, 'n', d.n, 'experts', coalesce(c.experts, 0),
                                       'per_expert', case when c.experts > 0 then round(d.n::numeric / c.experts, 1) end) w
                                from dep_first d left join cov c using (dep)
                               order by coalesce(c.experts, 0), d.n::numeric / nullif(c.experts, 0) desc nulls first, d.n desc
                               limit 6) x), '[]'),
    'monthly', (select jsonb_agg(jsonb_build_object(
                   'month', to_char(mo, 'YYYY-MM'),
                   'departments', (select count(*) from dep_first where first_at < mo + interval '1 month'),
                   'mandates', (select count(*) from m where created_at >= mo and created_at < mo + interval '1 month'),
                   'coverage_pct', (select round(100.0 * count(*) filter (where experts > 0) / nullif(count(*), 0))
                                      from mc where dep is not null and created_at >= mo and created_at < mo + interval '1 month')
                 ) order by mo) from months),
    'insurers', coalesce((select jsonb_agg(jsonb_build_object(
                   'id', ins.id, 'name', ins.name, 'zone_city', ins.catchment_city, 'zone_km', ins.r,
                   'mandates', (select count(*) from m where m.insurer_id = ins.id),
                   'departments', (select count(distinct dep) from m where m.insurer_id = ins.id and dep is not null),
                   'coverage_pct', (select round(100.0 * count(*) filter (where experts > 0) / nullif(count(*), 0))
                                      from mc where mc.insurer_id = ins.id and dep is not null)
                 ) order by ins.name) from ins), '[]')
  ) into v_res;
  return v_res;
end;
$$;
revoke all on function public.coverage_dashboard(int) from public, anon;
grant execute on function public.coverage_dashboard(int) to authenticated;
