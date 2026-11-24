-- Zone de danger, corrections après recette du 22/11/2026 :
-- 1) un gestionnaire retiré perd tous ses droits (is_manager / is_supervisor) et ses sessions sont fermées ;
-- 2) la purge des archives met aussi en file de suppression les fichiers des mandats purgés (photos, médias, PDF).

create or replace function public.is_manager()
 returns boolean language sql stable security definer set search_path to 'public'
as $function$ select exists (select 1 from public.user_profiles
                             where id = auth.uid() and role::text = 'gestionnaire_assurance' and removed_at is null) $function$;

create or replace function public.is_supervisor()
 returns boolean language sql stable security definer set search_path to 'public'
as $function$
  select exists (select 1 from public.user_profiles
                 where id = auth.uid() and role::text = 'gestionnaire_assurance' and is_supervisor and removed_at is null)
$function$;

create or replace function public.supervisor_remove_manager(p_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_org uuid;
begin
  if not public.is_supervisor() then raise exception 'Accès réservé au superviseur' using errcode = '42501'; end if;
  if p_id = auth.uid() then raise exception 'Vous ne pouvez pas retirer votre propre compte'; end if;
  select organization_id into v_org from user_profiles where id = auth.uid();
  if not exists (select 1 from user_profiles where id = p_id and organization_id = v_org and role::text = 'gestionnaire_assurance') then
    raise exception 'Gestionnaire introuvable dans votre équipe';
  end if;
  update user_profiles set removed_at = now(), is_supervisor = false,
         presence_status = 'offline', updated_at = now()
  where id = p_id;
  delete from mandate_locks where user_id = p_id;
  -- déconnexion immédiate : les jetons en cours ne peuvent plus être renouvelés
  delete from auth.sessions where user_id = p_id;
  delete from auth.refresh_tokens where user_id = p_id::text;
  insert into activity_logs (user_id, organization_id, entity_type, entity_id, action)
  values (auth.uid(), v_org, 'user', p_id, 'manager_removed');
end $function$;

create or replace function public.supervisor_archive_mandates(p_before timestamp with time zone, p_purge boolean default false)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_org uuid; v_ids uuid[]; v_archive jsonb; v_files int := 0;
begin
  if not public.is_supervisor() then raise exception 'Accès réservé au superviseur' using errcode = '42501'; end if;
  select organization_id into v_org from user_profiles where id = auth.uid();
  select coalesce(array_agg(id), '{}') into v_ids from mandates
   where insurance_org_id = v_org and status::text in ('closed', 'cancelled')
     and coalesce(closed_at, updated_at) < coalesce(p_before, 'infinity'::timestamptz);

  if not p_purge then
    select jsonb_build_object(
      'exported_at', now(), 'organization_id', v_org, 'before', p_before, 'count', cardinality(v_ids),
      'mandates', coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object(
          'beneficiary', (select to_jsonb(b) from beneficiaries b where b.id = m.beneficiary_id),
          'history', (select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at), '[]') from mandate_history h where h.mandate_id = m.id),
          'assignments', (select coalesce(jsonb_agg(to_jsonb(a)), '[]') from mandate_assignments a where a.mandate_id = m.id),
          'reports', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from rdf_reports r where r.mandate_id = m.id),
          'report_rooms', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from rdf_report_rooms r where r.mandate_id = m.id),
          'interventions', (select coalesce(jsonb_agg(to_jsonb(i)), '[]') from interventions i where i.mandate_id = m.id),
          'documents', (select coalesce(jsonb_agg(to_jsonb(d)), '[]') from documents d where d.mandate_id = m.id),
          'media', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from report_media x where x.mandate_id = m.id)
        ) order by m.created_at) from mandates m where m.id = any(v_ids)), '[]'))
      into v_archive;
    return v_archive;
  end if;

  -- Fichiers des mandats purgés (photos, vidéos, médias, PDF du rapport) : supprimés par purge-storage
  insert into storage_purge_queue (bucket, path, reason)
  select o.bucket_id, o.name, 'mandates_purge'
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
  values (auth.uid(), 'mandates_purged', 'user', auth.uid(),
          jsonb_build_object('count', cardinality(v_ids), 'before', p_before, 'files_queued', v_files));
  return jsonb_build_object('deleted', cardinality(v_ids), 'files_queued', v_files);
end $function$;
