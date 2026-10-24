-- 1. Policy documents : l'expert lit les documents de ses rapports (rdf_reports) ou de ses mandats
drop policy if exists "expert read own documents" on public.documents;
create policy "expert read own documents"
on public.documents for select
using (
  current_user_role() = 'expert'::app_role
  and (
    exists (
      select 1 from public.rdf_reports r
      where r.id = documents.report_id
        and r.created_by = auth.uid()
    )
    or exists (
      select 1
      from public.mandates m
      join public.mandate_assignments ma on ma.mandate_id = m.id
      join public.experts e on e.id = ma.expert_id
      where m.id = documents.mandate_id
        and e.user_id = auth.uid()
        and ma.status = any (array['pending'::assignment_status, 'accepted'::assignment_status])
    )
  )
);

-- 2. documents.report_id : détacher l'ancienne table et pointer vers rdf_reports
alter table public.documents drop constraint if exists documents_report_id_fkey;
update public.documents set report_id = null
where report_id is not null
  and report_id not in (select id from public.rdf_reports);
alter table public.documents
  add constraint documents_report_id_fkey
  foreign key (report_id) references public.rdf_reports(id) on delete set null;

-- 3. Suppression de l'ancienne table reports (données de test uniquement), ses triggers et policies
drop table public.reports;
drop function if exists public.trg_kpi_on_report();

-- 4. Clé étrangère en double sur rdf_reports (sans règle de suppression)
alter table public.rdf_reports drop constraint if exists fk_mandate;
