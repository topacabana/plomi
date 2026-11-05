-- PLOMI — PLO : sélection automatique d'experts par stratégie (CC mandataire B), validé le 05/11/2026
-- Score 0-100 par critère, relatif aux autres experts (100 = le meilleur) ; un expert est retenu
-- s'il atteint tous les seuils ; sans donnée sur un critère => écarté, sauf stratégie « recrutement ».

create table if not exists public.plo_strategies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete cascade,  -- null = modèle du CC
  code text unique,                                   -- rush, eco, commercial, recrutement, boost (modèles)
  name text not null,
  description text,
  precision_min int not null check (precision_min between 0 and 100),
  reactivite_min int not null check (reactivite_min between 0 and 100),
  rapidite_min int not null check (rapidite_min between 0 and 100),
  avis_client_min int not null check (avis_client_min between 0 and 100),
  include_no_data boolean not null default false,
  created_by_user_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.plo_strategies enable row level security;
drop policy if exists "plo : modèles et stratégies de mon organisation" on public.plo_strategies;
create policy "plo : modèles et stratégies de mon organisation" on public.plo_strategies
  for select to authenticated
  using (public.is_manager() and (organization_id is null or organization_id = public.current_user_organization_id()));

insert into public.plo_strategies (code, name, description, precision_min, reactivite_min, rapidite_min, avis_client_min, include_no_data) values
 ('rush', 'Stratégie rush', 'Gestion de flux dense', 70, 95, 95, 65, false),
 ('eco', 'Stratégie éco', 'Gestion au coût le plus optimisé (maximisation de drop simple)', 80, 95, 95, 65, false),
 ('commercial', 'Stratégie commercial', 'Maximisation des performances d''activité expert', 95, 95, 95, 95, false),
 ('recrutement', 'Stratégie recrutement', 'Utilisation de nouveaux profils experts (maximisation de visio-expertise)', 90, 70, 70, 70, true),
 ('boost', 'Stratégie boost', 'Test des profils « haute performance » (TOP 20 rapidité, précision, réactivité, avis client)', 95, 95, 95, 95, false)
on conflict (code) do nothing;

-- Scores 0-100 de chaque expert (null = pas de donnée)
create or replace function public.plo_expert_scores()
 returns table (expert_id uuid, precision_score int, reactivite_score int, rapidite_score int, avis_client_score int)
 language sql stable security definer set search_path to 'public'
as $$
  with base as (
    select e.id, e.rating,
           nullif(k.avg_response_time_min, 0) reac, nullif(k.avg_intervention_duration_min, 0) speed
      from public.experts e left join public.expert_kpis k on k.expert_id = e.id
     where coalesce(e.status_experts::text, 'new') <> 'suspendu'),
  prec as (
    select e.id,
           avg(coalesce(ph.n,0) + coalesce(cardinality(r.inspection_photos),0)) photos,
           avg(coalesce(length(r.rapport_conclusions),0) + coalesce(length(r.inspection_commentaires),0) + coalesce(ph.c,0)) chars
      from public.rdf_reports r join public.experts e on e.user_id = r.created_by
      left join lateral (select sum(coalesce(cardinality(rr.photos),0)) n, sum(coalesce(length(rr.commentaire),0)) c
                           from public.rdf_report_rooms rr where rr.report_id = r.id) ph on true
     where r.status in ('submitted','validated','completed') group by e.id),
  p2 as (select id, (percent_rank() over (order by photos) + percent_rank() over (order by chars)) / 2 v, count(*) over () n from prec),
  r2 as (select id, percent_rank() over (order by reac desc) v, count(*) over () n from base where reac is not null),
  s2 as (select id, percent_rank() over (order by speed desc) v, count(*) over () n from base where speed is not null),
  a2 as (select id, percent_rank() over (order by rating) v, count(*) over () n from base where rating is not null)
  select b.id,
         (select case when n = 1 then 100 else round(v * 100)::int end from p2 where p2.id = b.id),
         (select case when n = 1 then 100 else round(v * 100)::int end from r2 where r2.id = b.id),
         (select case when n = 1 then 100 else round(v * 100)::int end from s2 where s2.id = b.id),
         (select case when n = 1 then 100 else round(v * 100)::int end from a2 where a2.id = b.id)
    from base b
$$;

create or replace function public.plo_data()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return jsonb_build_object(
    'strategies', coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('is_template', s.organization_id is null)
                                             order by s.organization_id is not null, s.created_at)
                              from public.plo_strategies s where s.organization_id is null or s.organization_id = v_org), '[]'::jsonb),
    'scores', coalesce((select jsonb_agg(to_jsonb(x)) from public.plo_expert_scores() x), '[]'::jsonb));
end $$;

-- Experts retenus pour des seuils donnés
create or replace function public.plo_select(p_precision int, p_reactivite int, p_rapidite int, p_avis_client int,
                                            p_include_no_data boolean default false, p_strategy_id uuid default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_ids jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select coalesce(jsonb_agg(expert_id), '[]'::jsonb) into v_ids from public.plo_expert_scores() s
   where (case when s.precision_score   is null then coalesce(p_include_no_data, false) else s.precision_score   >= coalesce(p_precision, 0) end)
     and (case when s.reactivite_score  is null then coalesce(p_include_no_data, false) else s.reactivite_score  >= coalesce(p_reactivite, 0) end)
     and (case when s.rapidite_score    is null then coalesce(p_include_no_data, false) else s.rapidite_score    >= coalesce(p_rapidite, 0) end)
     and (case when s.avis_client_score is null then coalesce(p_include_no_data, false) else s.avis_client_score >= coalesce(p_avis_client, 0) end);
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', coalesce(p_strategy_id, gen_random_uuid()), 'plo_applied',
          jsonb_build_object('strategy_id', p_strategy_id, 'precision', p_precision, 'reactivite', p_reactivite,
                             'rapidite', p_rapidite, 'avis_client', p_avis_client, 'include_no_data', p_include_no_data,
                             'selected', jsonb_array_length(v_ids)));
  return v_ids;
end $$;

-- Créer (p_id null) ou sauvegarder une stratégie de l'organisation (les modèles ne se modifient pas)
create or replace function public.save_plo_strategy(p_id uuid, p_name text, p_precision int, p_reactivite int,
                                                   p_rapidite int, p_avis_client int)
 returns uuid language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id(); v_id uuid := p_id; v_name text := nullif(trim(coalesce(p_name,'')), '');
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if v_name is null then raise exception 'Nommez la stratégie'; end if;
  if least(p_precision, p_reactivite, p_rapidite, p_avis_client) < 0 or greatest(p_precision, p_reactivite, p_rapidite, p_avis_client) > 100 then
    raise exception 'Les seuils vont de 0 à 100 %%';
  end if;
  if v_id is null then
    insert into public.plo_strategies (organization_id, name, precision_min, reactivite_min, rapidite_min, avis_client_min, created_by_user_id)
    values (v_org, v_name, p_precision, p_reactivite, p_rapidite, p_avis_client, auth.uid()) returning id into v_id;
  else
    if not exists (select 1 from public.plo_strategies where id = v_id and organization_id = v_org) then
      raise exception 'Les modèles du cahier des charges ne se modifient pas : créez une nouvelle stratégie';
    end if;
    update public.plo_strategies set name = v_name, precision_min = p_precision, reactivite_min = p_reactivite,
           rapidite_min = p_rapidite, avis_client_min = p_avis_client, updated_at = now() where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function public.delete_plo_strategy(p_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  delete from public.plo_strategies where id = p_id and organization_id = public.current_user_organization_id();
  if not found then raise exception 'Stratégie introuvable (les modèles ne se suppriment pas)'; end if;
end $$;

revoke execute on function public.plo_expert_scores() from public, anon, authenticated;
revoke execute on function public.plo_data() from public, anon;
revoke execute on function public.plo_select(int, int, int, int, boolean, uuid) from public, anon;
revoke execute on function public.save_plo_strategy(uuid, text, int, int, int, int) from public, anon;
revoke execute on function public.delete_plo_strategy(uuid) from public, anon;
grant execute on function public.plo_expert_scores() to service_role;
grant execute on function public.plo_data() to authenticated, service_role;
grant execute on function public.plo_select(int, int, int, int, boolean, uuid) to authenticated, service_role;
grant execute on function public.save_plo_strategy(uuid, text, int, int, int, int) to authenticated, service_role;
grant execute on function public.delete_plo_strategy(uuid) to authenticated, service_role;
