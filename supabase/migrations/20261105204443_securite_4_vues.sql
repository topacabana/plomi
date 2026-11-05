-- Sécurité étape 4 : vues
-- a) Vues qui peuvent respecter directement la RLS des tables -> droits de l'utilisateur
alter view public.pending_mandates_with_beneficiaries set (security_invoker = true);
alter view public.mandate_lock_status set (security_invoker = true);

-- b) Vues qui affichent des noms (user_profiles n'est lisible que pour soi) ou des profils
--    d'experts : elles restent en droits du propriétaire mais filtrent elles-mêmes.
do $v$
declare d text;
begin
  -- experts avec profils : gestionnaires, ou l'expert pour sa propre fiche
  d := pg_get_viewdef('public.experts_with_profiles'::regclass);
  if position('GROUP BY e.id' in d) = 0 then raise exception 'motif experts_with_profiles'; end if;
  execute 'create or replace view public.experts_with_profiles as '
    || replace(d, 'GROUP BY e.id', 'WHERE (public.is_manager() OR e.user_id = auth.uid()) GROUP BY e.id');

  -- tableau KPI : gestionnaires, ou l'expert pour ses propres KPI
  d := pg_get_viewdef('public.vw_expert_kpis_dashboard'::regclass);
  if position('ORDER BY k.total_mandates DESC' in d) = 0 then raise exception 'motif kpi'; end if;
  execute 'create or replace view public.vw_expert_kpis_dashboard as '
    || replace(d, 'ORDER BY k.total_mandates DESC', 'WHERE (public.is_manager() OR e.user_id = auth.uid()) ORDER BY k.total_mandates DESC');

  -- historique : gestionnaires, mandats de leur organisation uniquement
  d := rtrim(pg_get_viewdef('public.mandate_history'::regclass), '; ');
  execute 'create or replace view public.mandate_history as ' || d
    || ' WHERE public.is_manager() AND EXISTS (SELECT 1 FROM public.mandates mm WHERE mm.id = ev.mandate_id AND mm.insurance_org_id = public.current_user_organization_id())';
end $v$;
