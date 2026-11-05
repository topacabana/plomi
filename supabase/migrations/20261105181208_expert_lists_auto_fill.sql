alter table public.expert_lists add column if not exists auto_rule text
  check (auto_rule in ('new_recruits','confirmed','agr_visio','agr_rdf','agr_rdfs','agr_full',
                       'top_reactivity','top_speed','top_precision','top_rating'));

update public.expert_lists set auto_rule = case name
  when 'Nouvelles recrues' then 'new_recruits'
  when 'Confirmé'          then 'confirmed'
  when 'Visio-expertise'   then 'agr_visio'
  when 'RDF'               then 'agr_rdf'
  when 'RDFS'              then 'agr_rdfs'
  when 'Full agrément'     then 'agr_full'
  when 'Réactivité'        then 'top_reactivity'
  when 'Rapidité'          then 'top_speed'
  when 'Précision'         then 'top_precision'
  when 'Note client'       then 'top_rating'
  end
where auto_rule is null;

create or replace function public.expert_list_rule_members(p_rule text)
 returns setof uuid language sql stable security definer set search_path to 'public'
as $$
  with k as (
    select e.id, lower(coalesce(e.agreements,'{}'::text[])::text)::text[] as agr, e.rating,
           coalesce(k.reports_submitted,0) as rdf,
           nullif(k.avg_response_time_min,0) as reac,
           nullif(k.avg_intervention_duration_min,0) as speed
      from public.experts e left join public.expert_kpis k on k.expert_id = e.id
  ),
  prec as (
    select e.id,
           avg(coalesce(ph.n,0) + coalesce(cardinality(r.inspection_photos),0)) as photos,
           avg(coalesce(length(r.rapport_conclusions),0) + coalesce(length(r.inspection_commentaires),0) + coalesce(ph.c,0)) as chars
      from public.rdf_reports r
      join public.experts e on e.user_id = r.created_by
      left join lateral (select sum(coalesce(cardinality(rr.photos),0)) n, sum(coalesce(length(rr.commentaire),0)) c
                           from public.rdf_report_rooms rr where rr.report_id = r.id) ph on true
     where r.status in ('submitted','validated','completed')
     group by e.id
  ),
  scored as (
    select 'top_reactivity' rule, id, reac  as v, true  asc_ from k where reac is not null
    union all select 'top_speed',  id, speed, true  from k where speed is not null
    union all select 'top_rating', id, rating, false from k where rating is not null
    union all select 'top_precision', id,
           ((percent_rank() over (order by photos) + percent_rank() over (order by chars)) / 2)::numeric, false from prec
  ),
  ranked as (
    select id, row_number() over (order by case when asc_ then v end asc, case when not asc_ then v end desc) rn,
           count(*) over () n
      from scored where rule = p_rule
  )
  select id from k where
       (p_rule = 'new_recruits' and rdf < 3)
    or (p_rule = 'confirmed'    and rdf > 20 and coalesce(rating,0) >= 4)
    or (p_rule = 'agr_visio'    and 'visio' = any(agr))
    or (p_rule = 'agr_rdf'      and 'rdf'   = any(agr))
    or (p_rule = 'agr_rdfs'     and 'rdfs'  = any(agr))
    or (p_rule = 'agr_full'     and agr @> array['visio','rdf','rdfs'])
  union
  select id from ranked where p_rule like 'top_%' and rn <= greatest(1, ceil(n * 0.2))
$$;

create or replace function public.refresh_auto_expert_lists()
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare l record; v_changes integer := 0; n integer;
begin
  for l in select id, auto_rule from public.expert_lists where auto_rule is not null and is_active loop
    delete from public.expert_list_members m
     where m.list_id = l.id and m.expert_id not in (select public.expert_list_rule_members(l.auto_rule));
    get diagnostics n = row_count; v_changes := v_changes + n;
    insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
    select l.id, x, null from public.expert_list_rule_members(l.auto_rule) x
    on conflict (list_id, expert_id) do nothing;
    get diagnostics n = row_count; v_changes := v_changes + n;
  end loop;
  return v_changes;
end $$;

create or replace function public.trg_refresh_auto_expert_lists()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$ begin perform public.refresh_auto_expert_lists(); return null; end $$;

drop trigger if exists trg_auto_lists_on_kpis on public.expert_kpis;
create trigger trg_auto_lists_on_kpis after insert or update on public.expert_kpis
  for each statement execute function public.trg_refresh_auto_expert_lists();

drop trigger if exists trg_auto_lists_on_experts on public.experts;
create trigger trg_auto_lists_on_experts after insert or update of agreements, rating on public.experts
  for each statement execute function public.trg_refresh_auto_expert_lists();

drop trigger if exists trg_auto_lists_on_list on public.expert_lists;
create trigger trg_auto_lists_on_list after insert or update of auto_rule, is_active on public.expert_lists
  for each statement execute function public.trg_refresh_auto_expert_lists();

grant execute on function public.refresh_auto_expert_lists() to authenticated;

select public.refresh_auto_expert_lists();
