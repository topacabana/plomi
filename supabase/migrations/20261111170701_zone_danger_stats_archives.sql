-- Zone de danger : réinitialisation des statistiques + archivage / suppression des données

alter table public.organizations add column if not exists stats_reset_at timestamptz;

-- 1) Réinitialisation des statistiques (non destructive : point zéro par organisation)
create or replace function public.supervisor_reset_stats()
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_at timestamptz := now();
begin
  if not public.is_supervisor() then raise exception 'Accès réservé au superviseur' using errcode = '42501'; end if;
  select organization_id into v_org from user_profiles where id = auth.uid();
  update organizations set stats_reset_at = v_at where id = v_org;
  insert into activity_logs (user_id, action, entity_type, entity_id, new_values_json)
  values (auth.uid(), 'stats_reset', 'user', auth.uid(), jsonb_build_object('at', v_at));
  return v_at;
end $$;
grant execute on function public.supervisor_reset_stats() to authenticated;

-- Les tableaux de bord ne comptent plus rien d'antérieur au point zéro
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.supervision_dashboard'::regproc);
  if position('stats_reset_at' in d) = 0 then
    n := regexp_replace(d, '(select\s+organization_id\s+into\s+v_org\s+from\s+user_profiles\s+where\s+id\s*=\s*auth\.uid\(\)\s*;)',
      E'\\1\n  select greatest(v_day, coalesce(o.stats_reset_at, v_day)), greatest(v_30, coalesce(o.stats_reset_at, v_30)) into v_day, v_30 from organizations o where o.id = v_org;');
    if n = d then raise exception 'ancre supervision_dashboard introuvable'; end if;
    execute n;
  end if;

  d := pg_get_functiondef('public.manager_detail'::regproc);
  if position('stats_reset_at' in d) = 0 then
    n := regexp_replace(d, '(if\s+v_card\s+is\s+null\s+then)',
      E'select greatest(v_since, coalesce(o.stats_reset_at, v_since)) into v_since from organizations o join user_profiles u on u.organization_id = o.id where u.id = auth.uid();\n  \\1');
    if n = d then raise exception 'ancre manager_detail introuvable'; end if;
    execute n;
  end if;

  d := pg_get_functiondef('public.manager_dashboard'::regproc);
  if position('stats_reset_at' in d) = 0 then
    n := regexp_replace(d, '(v_res\s+jsonb\s*;)',
      E'\\1\n  v_reset timestamptz := coalesce((select stats_reset_at from public.organizations where id = public.current_user_organization_id()), ''-infinity''::timestamptz);');
    if n = d then raise exception 'ancre manager_dashboard introuvable'; end if;
    n := regexp_replace(n, 'v_now\s*-\s*interval\s*''(\d+) days''', 'greatest(v_now - interval ''\1 days'', v_reset)', 'g');
    execute n;
  end if;
end $$;

-- 2) Archivage puis suppression des mandats clôturés / annulés
create or replace function public.supervisor_archive_mandates(p_before timestamptz, p_purge boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_ids uuid[]; v_archive jsonb;
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

  delete from mandate_history where mandate_id = any(v_ids);
  delete from mandates where id = any(v_ids);
  insert into activity_logs (user_id, action, entity_type, entity_id, new_values_json)
  values (auth.uid(), 'mandates_purged', 'user', auth.uid(), jsonb_build_object('count', cardinality(v_ids), 'before', p_before));
  return jsonb_build_object('deleted', cardinality(v_ids));
end $$;
grant execute on function public.supervisor_archive_mandates(timestamptz, boolean) to authenticated;
