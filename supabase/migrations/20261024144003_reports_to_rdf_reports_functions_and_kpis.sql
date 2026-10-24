-- =====================================================================
-- A. Données du PDF : lecture sur rdf_reports (et non plus reports)
-- =====================================================================
create or replace function public.get_rapport_preview_data(p_mandate_id uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
select jsonb_build_object(
  -- Mandat
  'mandate_id', m.id,
  'mandate_reference', m.reference,
  'mandate_date', to_char(m.created_at, 'DD/MM/YYYY'),
  'mandate_description', m.description,
  'mandate_status', m.status,
  'mandate_closed_at', to_char(m.closed_at, 'DD/MM/YYYY'),
  'defect_type', m.defect_type,
  'affected_rooms', m.affected_rooms,
  'location_address', concat_ws(' ', m.address_line_1, m.postal_code, m.city),
  -- Expert (auteur du rapport, à défaut l'expert assigné)
  'expert_id', e.id,
  'expert_name', coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), 'N/A'),
  'expert_phone', e.phone,
  'expert_email', e.email,
  'expert_company', e.company_name,
  'expert_siret', e.siret,
  -- Bénéficiaire
  'beneficiary_name', coalesce(nullif(concat_ws(' ', b.first_name, b.last_name), ''), 'N/A'),
  'beneficiary_phone', b.mobile_phone,
  'beneficiary_email', b.email,
  -- Assurance
  'insurance_name', org.name,
  -- Rapport d'expertise (dernier rapport non brouillon, sinon le brouillon)
  'report_id', r.id,
  'report_status', r.status,
  'report_submitted_at', to_char(r.submitted_at, 'DD/MM/YYYY'),
  'report_conclusions', r.rapport_conclusions,
  'report', to_jsonb(r) - 'id' - 'mandate_id' - 'created_by',
  -- Métadonnées
  'generation_date', to_char(now(), 'DD/MM/YYYY'),
  'generation_time', to_char(now(), 'HH24:MI:SS')
)
from public.mandates m
left join lateral (
  select x.*
  from public.rdf_reports x
  where x.mandate_id = m.id
  order by (x.status = 'draft'), x.created_at desc
  limit 1
) r on true
left join public.experts e on e.id = coalesce(
  (select ex.id from public.experts ex where ex.user_id = r.created_by),
  m.assigned_expert_id
)
left join public.beneficiaries b on b.id = m.beneficiary_id
left join public.organizations org on org.id = m.insurance_org_id
where m.id = p_mandate_id;
$$;

-- =====================================================================
-- B. KPI experts : rapports lus dans rdf_reports
--    soumis   = statut submitted ou completed
--    validés  = rapports remis dont le mandat est clôturé (validation sur le mandat)
--    rejetés  = rejected_at renseigné
-- =====================================================================
create or replace function public.recalculate_expert_kpis(p_expert_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_total_mandates integer;
  v_mandates_in_progress integer;
  v_mandates_completed integer;
  v_mandates_refused integer;
  v_redrop_caused integer;
  v_avg_response_time_min numeric;
  v_avg_intervention_duration_min numeric;
  v_avg_rating numeric;
  v_reports_submitted integer;
  v_reports_validated integer;
  v_reports_rejected integer;
  v_report_validation_rate numeric;
  v_mandates_last_30d integer;
  v_reports_last_30d integer;
  v_last_report_at timestamptz;
  v_last_activity_at timestamptz;
begin
  select count(*) into v_total_mandates
  from public.mandate_assignments
  where expert_id = p_expert_id and status in ('accepted', 'pending', 'refused');

  select count(*) into v_mandates_in_progress
  from public.mandate_assignments ma
  join public.mandates m on m.id = ma.mandate_id
  where ma.expert_id = p_expert_id and ma.status = 'accepted'
    and m.status in ('assigned', 'in_progress');

  select count(*) into v_mandates_completed
  from public.mandate_assignments ma
  join public.mandates m on m.id = ma.mandate_id
  where ma.expert_id = p_expert_id and ma.status = 'accepted'
    and m.status in ('closed');

  select count(*) into v_mandates_refused
  from public.mandate_assignments
  where expert_id = p_expert_id and status = 'refused';

  begin
    select coalesce(count(*), 0) into v_redrop_caused
    from public.expert_performance_logs
    where expert_id = p_expert_id and event_type = 'redrop_caused';
  exception when undefined_table then
    v_redrop_caused := 0;
  end;

  if v_redrop_caused = 0 then
    select coalesce(sum(m.redrop_count), 0) into v_redrop_caused
    from public.mandate_assignments ma
    join public.mandates m on m.id = ma.mandate_id
    where ma.expert_id = p_expert_id and ma.status = 'refused';
  end if;

  select coalesce(avg(extract(epoch from (ma.accepted_at - ma.assigned_at)) / 60), 0)
  into v_avg_response_time_min
  from public.mandate_assignments ma
  where ma.expert_id = p_expert_id and ma.status = 'accepted'
    and ma.accepted_at is not null and ma.assigned_at is not null;

  select coalesce(avg(extract(epoch from (i.actual_end_at - i.actual_start_at)) / 60), 0)
  into v_avg_intervention_duration_min
  from public.interventions i
  where i.expert_id = p_expert_id
    and i.actual_start_at is not null and i.actual_end_at is not null;

  select coalesce(rating, 0) into v_avg_rating
  from public.experts where id = p_expert_id;

  -- Rapports d'expertise (rdf_reports, auteur = experts.user_id)
  select
    count(*) filter (where r.status in ('submitted', 'completed')),
    count(*) filter (where r.status in ('submitted', 'completed') and m.status = 'closed'),
    count(*) filter (where r.rejected_at is not null),
    count(*) filter (where r.created_at >= now() - interval '30 days'),
    max(r.created_at)
  into v_reports_submitted, v_reports_validated, v_reports_rejected,
       v_reports_last_30d, v_last_report_at
  from public.rdf_reports r
  join public.experts e on e.user_id = r.created_by
  join public.mandates m on m.id = r.mandate_id
  where e.id = p_expert_id;

  if v_reports_submitted > 0 then
    v_report_validation_rate := (v_reports_validated::numeric / v_reports_submitted::numeric) * 100;
  else
    v_report_validation_rate := 0;
  end if;

  select count(*) into v_mandates_last_30d
  from public.mandate_assignments
  where expert_id = p_expert_id and assigned_at >= (now() - interval '30 days');

  -- Dernière activité (null si aucune activité)
  v_last_activity_at := nullif(greatest(
    coalesce((select max(assigned_at) from public.mandate_assignments where expert_id = p_expert_id), '-infinity'::timestamptz),
    coalesce(v_last_report_at, '-infinity'::timestamptz),
    coalesce((select max(created_at) from public.interventions where expert_id = p_expert_id), '-infinity'::timestamptz)
  ), '-infinity'::timestamptz);

  insert into public.expert_kpis (
    expert_id, total_mandates, mandates_in_progress, mandates_completed, mandates_refused,
    redrop_caused, avg_response_time_min, avg_intervention_duration_min, avg_rating,
    reports_submitted, reports_validated, reports_rejected, report_validation_rate,
    mandates_last_30d, reports_last_30d, last_activity_at, last_calculated_at, updated_at
  ) values (
    p_expert_id, v_total_mandates, v_mandates_in_progress, v_mandates_completed, v_mandates_refused,
    v_redrop_caused, v_avg_response_time_min, v_avg_intervention_duration_min, v_avg_rating,
    v_reports_submitted, v_reports_validated, v_reports_rejected, v_report_validation_rate,
    v_mandates_last_30d, v_reports_last_30d, v_last_activity_at, now(), now()
  )
  on conflict (expert_id) do update set
    total_mandates = excluded.total_mandates,
    mandates_in_progress = excluded.mandates_in_progress,
    mandates_completed = excluded.mandates_completed,
    mandates_refused = excluded.mandates_refused,
    redrop_caused = excluded.redrop_caused,
    avg_response_time_min = excluded.avg_response_time_min,
    avg_intervention_duration_min = excluded.avg_intervention_duration_min,
    avg_rating = excluded.avg_rating,
    reports_submitted = excluded.reports_submitted,
    reports_validated = excluded.reports_validated,
    reports_rejected = excluded.reports_rejected,
    report_validation_rate = excluded.report_validation_rate,
    mandates_last_30d = excluded.mandates_last_30d,
    reports_last_30d = excluded.reports_last_30d,
    last_activity_at = excluded.last_activity_at,
    last_calculated_at = now(),
    updated_at = now();
end;
$function$;

-- =====================================================================
-- C1. Trigger sur rdf_reports : soumission / changement de statut
-- =====================================================================
create or replace function public.trg_kpi_on_rdf_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expert uuid;
  v_log boolean := false;
begin
  select id into v_expert from public.experts where user_id = new.created_by;
  if v_expert is null then
    return new;
  end if;

  if new.status in ('submitted', 'completed') then
    if tg_op = 'INSERT' then
      v_log := true;
    elsif old.status = 'draft' then
      v_log := true;
    end if;
  end if;

  if v_log then
    insert into public.expert_performance_logs (expert_id, mandate_id, event_type, metadata)
    values (v_expert, new.mandate_id, 'report_submitted',
            jsonb_build_object('report_id', new.id, 'report_type', 'rdf'));
  end if;

  perform public.recalculate_expert_kpis(v_expert);
  return new;
end;
$$;

drop trigger if exists trg_kpi_on_rdf_report on public.rdf_reports;
create trigger trg_kpi_on_rdf_report
after insert or update of status, rejected_at on public.rdf_reports
for each row execute function public.trg_kpi_on_rdf_report();

-- =====================================================================
-- C2. Trigger sur mandates : clôture (= validation par le gestionnaire)
-- =====================================================================
create or replace function public.trg_kpi_on_mandate_closed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expert uuid;
begin
  for v_expert in
    select distinct e.id
    from public.rdf_reports r
    join public.experts e on e.user_id = r.created_by
    where r.mandate_id = new.id
  loop
    if new.status = 'closed' then
      insert into public.expert_performance_logs (expert_id, mandate_id, event_type, metadata)
      values (v_expert, new.id, 'report_validated',
              jsonb_build_object('validated_by', auth.uid()));
    end if;
    perform public.recalculate_expert_kpis(v_expert);
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_kpi_on_mandate_closed on public.mandates;
create trigger trg_kpi_on_mandate_closed
after update of status on public.mandates
for each row
when (old.status is distinct from new.status and (new.status = 'closed' or old.status = 'closed'))
execute function public.trg_kpi_on_mandate_closed();
