-- Liste des experts pour le menu et l'attribution (application mandataire).
-- Remplace la lecture directe de la vue experts_with_profiles en JavaScript dans WeWeb :
-- le front appelle désormais cette fonction avec l'action native « Call Postgres function ».
-- Réservée aux gestionnaires (liste vide sinon), mêmes champs et même tri qu'avant.

create or replace function public.experts_menu_list()
returns jsonb
language sql
stable
security invoker
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(to_jsonb(e) order by e.last_name nulls last, e.first_name), '[]'::jsonb)
    from (
      select id, user_id, first_name, last_name, company_name, trade_name, city, postal_code,
             phone, email, status_experts, suspended_at, is_online, specialty
        from public.experts_with_profiles
    ) e
   where public.is_manager();
$$;

revoke all on function public.experts_menu_list() from public, anon;
grant execute on function public.experts_menu_list() to authenticated;
