-- Zone de danger : suppression d'un assureur.
-- Aucun mandat rattaché  -> la fiche est supprimée (ses imports vides avec), logo compris côté client.
-- Des mandats rattachés  -> la fiche est archivée : les mandats gardent leur assureur et leur n° de dossier.
create or replace function public.insurer_delete(p_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_name text;
  v_count int;
begin
  if not public.is_manager() then raise exception 'Action réservée aux gestionnaires'; end if;
  select name into v_name from insurers where id = p_id and organization_id = v_org;
  if v_name is null then raise exception 'Assureur introuvable'; end if;

  select count(*) into v_count from mandates where insurer_id = p_id;
  if v_count = 0 then
    delete from mandate_imports where insurer_id = p_id and organization_id = v_org;
    delete from insurers where id = p_id;
    return jsonb_build_object('mode', 'deleted', 'name', v_name, 'mandates', 0);
  end if;

  update insurers set archived_at = coalesce(archived_at, now()), updated_at = now() where id = p_id;
  return jsonb_build_object('mode', 'archived', 'name', v_name, 'mandates', v_count);
end;
$$;
revoke all on function public.insurer_delete(uuid) from public, anon;
grant execute on function public.insurer_delete(uuid) to authenticated;
