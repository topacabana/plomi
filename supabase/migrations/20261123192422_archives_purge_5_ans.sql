-- Archives : téléchargement PDF puis suppression définitive, durée minimale de conservation 5 ans.
-- p_mode = 'all'     : supprime toutes les archives demandées (y compris celles de moins de 5 ans, choix explicite)
-- p_mode = 'older5'  : supprime uniquement celles clôturées depuis plus de 5 ans ; les autres sont conservées
-- Seuls les mandats clôturés ou annulés de l'organisation sont concernés. Fichiers mis en file de purge.
create or replace function public.manager_archives_purge(p_ids uuid[], p_mode text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_user_organization_id();
  v_ids uuid[];
  v_kept int;
  v_files int := 0;
  v_refs text[];
begin
  if not public.is_manager() then raise exception 'Action réservée aux gestionnaires' using errcode = '42501'; end if;
  if p_mode not in ('all', 'older5') then raise exception 'Mode inconnu (all ou older5)'; end if;
  if coalesce(cardinality(p_ids), 0) = 0 then return jsonb_build_object('deleted', 0, 'kept', 0, 'files_queued', 0); end if;

  select coalesce(array_agg(m.id), '{}'), coalesce(array_agg(m.reference), '{}') into v_ids, v_refs
    from mandates m
   where m.id = any(p_ids) and m.insurance_org_id = v_org and m.status::text in ('closed', 'cancelled')
     and (p_mode = 'all' or coalesce(m.closed_at, m.updated_at) < now() - interval '5 years');

  select count(*) into v_kept from mandates m
   where m.id = any(p_ids) and m.insurance_org_id = v_org and not (m.id = any(v_ids));

  if cardinality(v_ids) = 0 then
    return jsonb_build_object('deleted', 0, 'kept', v_kept, 'files_queued', 0);
  end if;

  insert into storage_purge_queue (bucket, path, reason)
  select o.bucket_id, o.name, 'archives_purge'
    from storage.objects o
   where o.bucket_id = 'documents'
     and split_part(o.name, '/', 1) = 'rapports'
     and split_part(o.name, '/', 2) = any (select x::text from unnest(v_ids) x)
     and not exists (select 1 from storage_purge_queue q where q.bucket = o.bucket_id and q.path = o.name and q.done_at is null);
  get diagnostics v_files = row_count;

  delete from activity_logs l
   where (l.entity_type = 'mandate' and l.entity_id = any(v_ids))
      or (l.entity_type = 'report' and l.entity_id in (select r.id from rdf_reports r where r.mandate_id = any(v_ids)))
      or (l.entity_type = 'assignment' and l.entity_id in (select a.id from mandate_assignments a where a.mandate_id = any(v_ids)));
  delete from mandates where id = any(v_ids);

  insert into activity_logs (user_id, action, entity_type, entity_id, new_values_json)
  values (auth.uid(), 'archives_purged', 'user', auth.uid(),
          jsonb_build_object('mode', p_mode, 'count', cardinality(v_ids), 'references', to_jsonb(v_refs),
                             'kept', v_kept, 'files_queued', v_files));
  return jsonb_build_object('deleted', cardinality(v_ids), 'kept', v_kept, 'files_queued', v_files);
end $function$;
revoke all on function public.manager_archives_purge(uuid[], text) from public, anon;
grant execute on function public.manager_archives_purge(uuid[], text) to authenticated;
