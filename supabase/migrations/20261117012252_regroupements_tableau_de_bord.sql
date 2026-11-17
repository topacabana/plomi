-- Regroupements pour le front WeWeb sans JavaScript : une seule action native
-- « Call Postgres function » par workflow, au lieu de plusieurs appels en JavaScript.

-- Tableau de bord : données du gestionnaire + supervision + zone de danger.
-- La supervision est réservée au superviseur : pour les autres, liste vide (comme avant).
create or replace function public.dashboard_bundle()
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public'
as $$
declare v_sup jsonb := '[]'::jsonb;
begin
  begin
    v_sup := coalesce(public.supervision_dashboard(), '[]'::jsonb);
  exception when others then
    v_sup := '[]'::jsonb;
  end;
  return jsonb_build_object(
    'dashboard', public.manager_dashboard(),
    'supervision', v_sup,
    'danger', case when jsonb_array_length(case when jsonb_typeof(v_sup) = 'array' then v_sup else '[]'::jsonb end) > 0
                   then public.danger_mandates_list() else '[]'::jsonb end);
end $$;

-- Couverture : indicateurs (rayon 30 km par défaut) + croissance sur 12 mois.
create or replace function public.coverage_bundle()
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public'
as $$
declare v_cov jsonb; v_growth jsonb;
begin
  begin v_cov := public.coverage_dashboard(); exception when others then v_cov := null; end;
  begin v_growth := public.coverage_growth(); exception when others then v_growth := null; end;
  return jsonb_build_object('coverage', v_cov, 'growth', v_growth);
end $$;

revoke all on function public.dashboard_bundle() from public, anon;
revoke all on function public.coverage_bundle() from public, anon;
grant execute on function public.dashboard_bundle() to authenticated;
grant execute on function public.coverage_bundle() to authenticated;
