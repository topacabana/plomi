-- Phase 1 : les experts de la base VELAY BAT (org_experts) deviennent salariés de VELAY BAT.
-- Les autres (vivier du recrutement) restent indépendants (valeur par défaut).
update public.experts e set employment_status = 'salarie_velaybat', company_name = 'VELAY BAT', contract_type = null
where exists (select 1 from public.org_experts oe
              where oe.expert_id = e.id and oe.organization_id = '00000001-0000-4000-8000-000000000001')
  and e.company_name <> 'Expert supprimé';
