-- RGPD A6 — durées de conservation (validées le 14/11/2026, cf. Audit RGPD § Conservation)
--  · codes d'accès effacés dès la clôture / annulation du mandat
--  · bénéficiaires orphelins (aucun mandat) supprimés après 30 jours
--  · journaux d'activité purgés après 12 mois
--  · mandats clôturés/annulés depuis plus de 5 ans anonymisés (adresse, contacts, notes,
--    bénéficiaire) ; coordonnées arrondies à ~1 km pour garder les statistiques de couverture
-- p_dry_run = true : ne modifie rien, renvoie seulement les volumes concernés.
create or replace function public.retention_sweep(p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_codes int; v_orphans int; v_logs int; v_anon int;
  c_old constant timestamptz := now() - interval '5 years';
begin
  select count(*) into v_codes from mandates
   where status::text in ('closed', 'cancelled') and entry_code is not null;
  select count(*) into v_orphans from beneficiaries b
   where b.created_at < now() - interval '30 days'
     and not exists (select 1 from mandates m where m.beneficiary_id = b.id);
  select count(*) into v_logs from activity_logs where created_at < now() - interval '12 months';
  select count(*) into v_anon from mandates
   where status::text in ('closed', 'cancelled') and coalesce(closed_at, updated_at) < c_old
     and address_line_1 <> 'Adresse anonymisée';

  if not p_dry_run then
    update mandates set entry_code = null
     where status::text in ('closed', 'cancelled') and entry_code is not null;

    delete from beneficiaries b
     where b.created_at < now() - interval '30 days'
       and not exists (select 1 from mandates m where m.beneficiary_id = b.id);

    delete from activity_logs where created_at < now() - interval '12 months';

    with old as (
      update mandates set
        address_line_1 = 'Adresse anonymisée', address_line_2 = null, floor = null, entry_code = null,
        secondary_contact_first_name = null, secondary_contact_last_name = null,
        secondary_contact_mobile = null, secondary_contact_phone = null, secondary_contact_role = null,
        internal_notes = null, comments = null, description = null, symptoms = null,
        latitude = round(latitude, 2), longitude = round(longitude, 2)
       where status::text in ('closed', 'cancelled') and coalesce(closed_at, updated_at) < c_old
         and address_line_1 <> 'Adresse anonymisée'
      returning beneficiary_id)
    update beneficiaries b set first_name = 'Anonymisé', last_name = 'Anonymisé',
           mobile_phone = null, landline_phone = null, email = null
     where b.id in (select beneficiary_id from old)
       and not exists (select 1 from mandates m where m.beneficiary_id = b.id
                        and not (m.status::text in ('closed', 'cancelled') and coalesce(m.closed_at, m.updated_at) < c_old));
  end if;

  return jsonb_build_object('dry_run', p_dry_run, 'at', now(),
    'entry_codes_cleared', v_codes, 'orphan_beneficiaries_deleted', v_orphans,
    'logs_purged', v_logs, 'mandates_anonymized', v_anon);
end $$;

revoke execute on function public.retention_sweep(boolean) from public, anon, authenticated;
grant execute on function public.retention_sweep(boolean) to service_role;

-- Mensuel : le 1er de chaque mois à 04h23 (UTC).
select cron.schedule('retention_sweep', '23 4 1 * *', $$select public.retention_sweep(false)$$);
