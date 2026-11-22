-- PLOMI — Nettoyage des données de test (avant les imports de démonstration)
-- Usage : à exécuter dans l'éditeur SQL Supabase (rôle postgres), en une fois. Tout ou rien : une seule transaction.
-- Conserve : organisations, comptes, experts, listes, assureurs, CGU, stratégies PLO, référentiels, sessions.
-- Supprime : mandats et tout ce qui en dépend, bénéficiaires, journaux, notifications, KPI et décisions PLO.
-- Les fichiers (photos, médias, PDF, exports) sont mis en file de suppression puis effacés par l'Edge Function purge-storage.
-- Faire une sauvegarde avant (export JSON des tables concernées) : la suppression est définitive.

begin;

-- 1. Fichiers du stockage : mis en file (Supabase interdit de les supprimer directement en SQL)
insert into public.storage_purge_queue (bucket, path, reason)
select o.bucket_id, o.name, 'nettoyage_donnees_test'
  from storage.objects o
 where o.bucket_id = 'documents'
   and split_part(o.name, '/', 1) in ('rapports', 'exports')
   and not exists (select 1 from public.storage_purge_queue q where q.bucket = o.bucket_id and q.path = o.name and q.done_at is null);

-- 2. Tout ce qui dépend d'un mandat, du plus profond au plus haut
delete from public.destructive_consents;
delete from public.presence_verifications;
delete from public.report_media;
delete from public.documents;
delete from public.rdf_report_rooms;
delete from public.rdf_reports;
delete from public.investigation_reports;
delete from public.interventions;
delete from public.mandate_assignments;
delete from public.mandate_locks;
delete from public.notifications;
delete from public.expert_performance_logs;
delete from public.plo_contestations;
delete from public.plo_decision_experts;
delete from public.plo_decisions;
delete from public.mandates;
delete from public.mandate_imports;
delete from public.beneficiaries;

-- 3. Journaux et indicateurs recalculés à partir de zéro
delete from public.activity_logs;
delete from public.expert_kpis;
delete from public.expert_fiche_locks;
update public.organizations set stats_reset_at = null where stats_reset_at is not null;

-- 4. Experts : levée des suspensions de test (les experts effacés pour le RGPD restent anonymisés et suspendus)
update public.experts
   set status_experts = coalesce(status_before_suspension::text, 'deconnecte')::public.expert_status,
       suspended_at = null, suspended_by = null, suspension_reason = null, status_before_suspension = null,
       updated_at = now()
 where status_experts = 'suspendu'
   and company_name is distinct from 'Expert supprimé';

-- 5. Contrôle : tout doit valoir 0, sinon la transaction est annulée
do $$
declare v int;
begin
  select (select count(*) from public.mandates) + (select count(*) from public.beneficiaries)
       + (select count(*) from public.rdf_reports) + (select count(*) from public.notifications)
       + (select count(*) from public.expert_performance_logs) + (select count(*) from public.activity_logs)
    into v;
  if v <> 0 then raise exception 'Nettoyage incomplet : % lignes restantes', v; end if;
end $$;

commit;

-- 6. Déclencher tout de suite la suppression des fichiers (sinon : prochain passage horaire du cron purge_storage)
select net.http_post(
  url := 'https://ybbzfedbdjgcahqajltm.supabase.co/functions/v1/purge-storage',
  headers := '{"Content-Type":"application/json"}'::jsonb,
  body := jsonb_build_object('token', (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token')),
  timeout_milliseconds := 60000);
