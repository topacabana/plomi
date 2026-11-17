-- Zone de danger du tableau de bord : mandats encore annulables (superviseur uniquement).
-- Remplace la lecture directe de la table mandates en JavaScript dans WeWeb :
-- le front appelle cette fonction avec l'action native « Call Postgres function ».
-- security invoker : les règles RLS de mandates s'appliquent comme avant ; liste vide hors superviseur.

create or replace function public.danger_mandates_list()
returns jsonb
language sql
stable
security invoker
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'reference', m.reference, 'city', m.city, 'postal_code', m.postal_code, 'status', m.status)
           order by m.created_at desc), '[]'::jsonb)
    from public.mandates m
   where public.is_supervisor()
     and m.status in ('draft', 'new', 'drop_pending', 'dropped', 'redrop', 'assigned', 'suspended');
$$;

revoke all on function public.danger_mandates_list() from public, anon;
grant execute on function public.danger_mandates_list() to authenticated;
