-- Statut 'validated' autorisé sur rdf_reports (aligné sur l'enum report_status)
alter table public.rdf_reports drop constraint check_status;
alter table public.rdf_reports add constraint check_status
  check (status::text = any (array['draft','submitted','completed','validated']));

-- À la clôture d'un mandat, le rapport envoyé passe en 'validated'
create or replace function public.trg_validate_report_on_close()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  update public.rdf_reports
     set status = 'validated', validated_at = now(), validated_by_user_id = auth.uid()
   where mandate_id = new.id and status = 'submitted';
  return new;
end $$;

drop trigger if exists trg_validate_report_on_close on public.mandates;
create trigger trg_validate_report_on_close
  after update of status on public.mandates
  for each row when (old.status is distinct from new.status and new.status = 'closed')
  execute function public.trg_validate_report_on_close();

-- Rattrapage des mandats déjà clôturés
update public.rdf_reports r set status = 'validated', validated_at = m.closed_at
  from public.mandates m
 where m.id = r.mandate_id and m.status = 'closed' and r.status = 'submitted';
