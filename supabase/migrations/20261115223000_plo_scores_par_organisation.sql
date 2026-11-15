-- AIPD C4, actions R1 et R3 : scores PLO calculés par assureur et orientés qualité.
-- R3 : population = experts rattachés à l'organisation qui décide ; réactivité, rapidité et
--      précision calculées sur les seules missions de cette organisation.
-- R1 : « Précision » = taux de rapports validés (et non plus volume de photos et de texte) ;
--      « Rapidité » = durée d'intervention rapportée à la médiane du même type de mandat.
-- Rangs en distribution cumulée (cume_dist) : les ex aequo partagent le meilleur rang.
-- Limite connue : la note client (experts.rating) reste une note globale, faute de note par mission.
-- plo_expert_scores() (global) est conservée pour le recrutement et les statistiques de l'expert.
create or replace function public.plo_expert_scores_org(p_org uuid)
returns table(expert_id uuid, precision_score integer, reactivite_score integer, rapidite_score integer, avis_client_score integer)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with pop as (
    select e.id, e.user_id, e.rating
      from public.experts e
      join public.org_experts oe on oe.expert_id = e.id and oe.organization_id = p_org
     where coalesce(e.status_experts::text, 'new') <> 'suspendu'),
  reac as (
    select ma.expert_id as id, avg(extract(epoch from ma.accepted_at - ma.assigned_at) / 60) v
      from public.mandate_assignments ma
      join public.mandates m on m.id = ma.mandate_id and m.insurance_org_id = p_org
     where ma.status = 'accepted' and ma.accepted_at is not null and ma.assigned_at is not null
       and ma.accepted_at >= ma.assigned_at
     group by 1),
  dur as (
    select p.id, m.mandate_type::text as mtype, extract(epoch from r.submitted_at - m.started_at) / 60 d
      from public.rdf_reports r
      join pop p on p.user_id = r.created_by
      join public.mandates m on m.id = r.mandate_id and m.insurance_org_id = p_org
     where r.submitted_at is not null and m.started_at is not null and r.submitted_at > m.started_at),
  med as (select mtype, percentile_cont(0.5) within group (order by d) md from dur group by 1),
  speed as (select dur.id, avg(dur.d / nullif(med.md, 0)) v from dur join med using (mtype) group by 1),
  prec as (
    select p.id,
           count(*) filter (where r.status::text in ('validated', 'completed')
                              or (r.status::text = 'submitted' and m.status::text = 'closed')) ok,
           count(*) filter (where r.rejected_at is not null) ko
      from public.rdf_reports r
      join pop p on p.user_id = r.created_by
      join public.mandates m on m.id = r.mandate_id and m.insurance_org_id = p_org
     group by 1),
  r2 as (select id, cume_dist() over (order by v desc) c from reac where v is not null and id in (select id from pop)),
  s2 as (select id, cume_dist() over (order by v desc) c from speed where v is not null),
  a2 as (select id, cume_dist() over (order by rating) c from pop where rating is not null)
  select p.id,
         (select round(100.0 * ok / (ok + ko))::int from prec where prec.id = p.id and ok + ko > 0),
         (select round(c * 100)::int from r2 where r2.id = p.id),
         (select round(c * 100)::int from s2 where s2.id = p.id),
         (select round(c * 100)::int from a2 where a2.id = p.id)
    from pop p
$$;

revoke execute on function public.plo_expert_scores_org(uuid) from public, anon, authenticated;
grant execute on function public.plo_expert_scores_org(uuid) to service_role;

-- La PLO (sélection et affichage des scores dans la popup) utilise désormais le calcul par organisation.
alter table public.plo_decisions alter column rule_version set default 3;

do $d$
declare v text;
begin
  v := pg_get_functiondef('public.plo_select(integer,integer,integer,integer,boolean,uuid)'::regprocedure);
  v := replace(v, 'from public.plo_expert_scores() x', 'from public.plo_expert_scores_org(v_org) x');
  if v !~ 'plo_expert_scores_org\(v_org\)' then raise exception 'plo_select : remplacement non appliqué'; end if;
  execute v;

  v := pg_get_functiondef('public.plo_data()'::regprocedure);
  v := replace(v, 'from public.plo_expert_scores() x', 'from public.plo_expert_scores_org(v_org) x');
  if v !~ 'plo_expert_scores_org\(v_org\)' then raise exception 'plo_data : remplacement non appliqué'; end if;
  execute v;
end $d$;
