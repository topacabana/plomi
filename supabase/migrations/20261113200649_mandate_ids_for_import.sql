-- Ids des mandats rattachés à un import CSV (filtre « Import » des listes Liste de drop / Current drop / Archives).
create or replace function public.mandate_ids_for_import(p_import_id uuid)
returns uuid[]
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce(array_agg(m.id), '{}')
  from mandates m
  join mandate_imports mi on mi.id = m.import_id
  where public.is_manager()
    and mi.organization_id = public.current_user_organization_id()
    and m.import_id = p_import_id;
$$;
revoke all on function public.mandate_ids_for_import(uuid) from public, anon;
grant execute on function public.mandate_ids_for_import(uuid) to authenticated;
