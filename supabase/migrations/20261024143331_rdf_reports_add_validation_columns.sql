-- Circuit de validation des rapports d'expertise (F56)
-- Colonnes reprises de l'ancienne table reports, ajoutées à rdf_reports
alter table public.rdf_reports
  add column if not exists submitted_at         timestamptz,
  add column if not exists validated_at         timestamptz,
  add column if not exists validated_by_user_id uuid references public.user_profiles(id) on delete set null,
  add column if not exists rejected_at          timestamptz,
  add column if not exists rejection_reason     text,
  add column if not exists pdf_url              text;

comment on column public.rdf_reports.submitted_at         is 'Date de soumission du rapport par l''expert';
comment on column public.rdf_reports.validated_at         is 'Date de validation par le gestionnaire assurance';
comment on column public.rdf_reports.validated_by_user_id is 'Gestionnaire ayant validé ou rejeté le rapport';
comment on column public.rdf_reports.rejected_at          is 'Date de rejet par le gestionnaire';
comment on column public.rdf_reports.rejection_reason     is 'Motif de rejet saisi par le gestionnaire';
comment on column public.rdf_reports.pdf_url              is 'Chemin du PDF généré dans le stockage';

-- Reprise de l''existant : les rapports déjà soumis ou terminés reçoivent une date de soumission approximative
update public.rdf_reports
set submitted_at = coalesce(updated_at, created_at)
where status in ('submitted', 'completed') and submitted_at is null;
