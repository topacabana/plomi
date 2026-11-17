-- Tableau de bord : croissance de la couverture sur 12 mois.
-- Chaque recrutement d'expert est classé selon sa zone déclarée (experts.coverage_zone) :
--   extension = sa zone apporte au moins un département qu'aucun expert recruté avant lui ne couvrait ;
--   renfort   = tous ses départements étaient déjà couverts ;
--   sans zone = aucune zone exploitable dans son profil.
create or replace function public.coverage_growth()
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

  with rec as (
    select e.id, e.created_at, public.coverage_zone_departments(e.coverage_zone) deps
      from experts e where coalesce(e.last_name, '') <> 'supprimé'
  ),
  cls as (   -- départements apportés par chaque recrutement
    select r.id, r.created_at, r.deps,
           array(select unnest(r.deps) except
                 select unnest(p.deps) from rec p where (p.created_at, p.id) < (r.created_at, r.id)) new_deps
      from rec r
  ),
  kind as (
    select *, case when cardinality(deps) = 0 then 'sans_zone'
                   when cardinality(new_deps) > 0 then 'extension' else 'renfort' end k
      from cls
  ),
  act as (   -- départements d'activité (mandats de l'organisation), date du premier mandat
    select left(m.postal_code, 2) dep, min(m.created_at) first_at
      from mandates m
     where m.insurance_org_id = v_org and m.status::text not in ('draft', 'cancelled') and m.postal_code ~ '^[0-9]{2}'
     group by 1
  ),
  months as (
    select generate_series(date_trunc('month', v_now) - interval '11 months', date_trunc('month', v_now), interval '1 month') mo
  )
  select jsonb_build_object(
    'monthly', (select jsonb_agg(jsonb_build_object(
        'month', to_char(mo, 'YYYY-MM'),
        'extension', (select count(*) from kind where k = 'extension' and created_at >= mo and created_at < mo + interval '1 month'),
        'renfort',   (select count(*) from kind where k = 'renfort'   and created_at >= mo and created_at < mo + interval '1 month'),
        'sans_zone', (select count(*) from kind where k = 'sans_zone' and created_at >= mo and created_at < mo + interval '1 month'),
        'new_departments', (select count(distinct d) from kind, unnest(new_deps) d where created_at >= mo and created_at < mo + interval '1 month'),
        'covered_departments', (select count(distinct d) from rec, unnest(deps) d where created_at < mo + interval '1 month'),
        'activity_departments', (select count(*) from act where first_at < mo + interval '1 month')
      ) order by mo) from months),
    'last12', jsonb_build_object(
        'recruited', (select count(*) from kind where created_at >= date_trunc('month', v_now) - interval '11 months'),
        'extension', (select count(*) from kind where k = 'extension' and created_at >= date_trunc('month', v_now) - interval '11 months'),
        'renfort',   (select count(*) from kind where k = 'renfort'   and created_at >= date_trunc('month', v_now) - interval '11 months'),
        'sans_zone', (select count(*) from kind where k = 'sans_zone' and created_at >= date_trunc('month', v_now) - interval '11 months'),
        'new_departments', (select count(distinct d) from kind, unnest(new_deps) d where created_at >= date_trunc('month', v_now) - interval '11 months'))
  ) into v_res;
  return v_res;
end;
$$;
revoke all on function public.coverage_growth() from public, anon;
grant execute on function public.coverage_growth() to authenticated;
