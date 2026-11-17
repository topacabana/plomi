-- Tableau de bord : alignement sur la suspension des EXPERTS.
--  * « Suspension imminente » = expert (créneau non honoré / prise sur carte non démarrée), hors attribution manuelle
--  * Nouvelle urgence « contact_48h » : attribution manuelle non démarrée depuis 48 h (indicateur seulement)
--  * Intervention > 2 h : simple repère (plus de suspension)
--  * Équipe : nombre et liste des experts suspendus
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.manager_dashboard()'::regprocedure);
  if position('''Suspension automatique '' || case when d.deadline <= v_now then ''imminente''' in d) = 0 then raise exception 'ancre 1a'; end if;
  d := replace(d, '''Suspension automatique '' || case when d.deadline <= v_now then ''imminente''',
                  '''Suspension de l''''expert '' || case when d.deadline <= v_now then ''imminente''');
  if position('     where m.status = ''assigned'' and m.started_at is null and m.assigned_at is not null
       and d.deadline <= v_now + interval ''2 hours''' in d) = 0 then raise exception 'ancre 1b'; end if;
  d := replace(d, '     where m.status = ''assigned'' and m.started_at is null and m.assigned_at is not null
       and d.deadline <= v_now + interval ''2 hours''',
'     where m.status = ''assigned'' and m.started_at is null and m.assigned_at is not null
       and coalesce(a.assignment_type::text, '''') <> ''manual''
       and d.deadline <= v_now + interval ''2 hours''
    union all
    -- Attribution manuelle : prise de contact attendue sous 48 h (indicateur, aucune action automatique)
    select m.id, m.reference, m.status::text, m.city, m.priority::text, m.expert_name,
           case when m.assigned_at <= v_now - interval ''72 hours'' then 2 else 3 end,
           ''Prise de contact non faite depuis '' || public.dashboard_duration(v_now - m.assigned_at) || '' (délai 48 h)'',
           m.assigned_at + interval ''48 hours'', ''contact_48h''
      from m join a on a.mandate_id = m.id
     where m.status = ''assigned'' and m.started_at is null and a.assignment_type = ''manual''
       and m.assigned_at <= v_now - interval ''48 hours''');
  if position('''En cours depuis '' || public.dashboard_duration(v_now - m.started_at) || '' : suspension automatique à 2 h''' in d) = 0 then raise exception 'ancre 2a'; end if;
  d := replace(d, '''En cours depuis '' || public.dashboard_duration(v_now - m.started_at) || '' : suspension automatique à 2 h''',
                  '''En cours depuis '' || public.dashboard_duration(v_now - m.started_at) || '' (repère 2 h dépassé)''');
  if position('case when m.started_at <= v_now - interval ''1 hour 50 minutes'' then 1 else 2 end' in d) = 0 then raise exception 'ancre 2b'; end if;
  d := replace(d, 'case when m.started_at <= v_now - interval ''1 hour 50 minutes'' then 1 else 2 end',
                  'case when m.started_at <= v_now - interval ''4 hours'' then 2 else 3 end');
  if position('from m where m.status = ''in_progress'' and m.started_at <= v_now - interval ''90 minutes''' in d) = 0 then raise exception 'ancre 2c'; end if;
  d := replace(d, 'from m where m.status = ''in_progress'' and m.started_at <= v_now - interval ''90 minutes''',
                  'from m where m.status = ''in_progress'' and m.started_at <= v_now - interval ''2 hours''');
  if position('''busy'',       (select count(distinct assigned_expert_id) from m where status in (''assigned'',''in_progress'')),' in d) = 0 then raise exception 'ancre 3'; end if;
  d := replace(d, '''busy'',       (select count(distinct assigned_expert_id) from m where status in (''assigned'',''in_progress'')),',
                  '''busy'',       (select count(distinct assigned_expert_id) from m where status in (''assigned'',''in_progress'')),
        ''suspended'',  count(distinct e.id) filter (where e.status_experts = ''suspendu''),
        ''suspended_list'', coalesce((select jsonb_agg(jsonb_build_object(''id'', x.id, ''name'', coalesce(nullif(trim(concat_ws('' '', x.first_name, x.last_name)), ''''), x.company_name), ''since'', x.suspended_at, ''reason'', x.suspension_reason) order by x.suspended_at desc)
                              from public.org_experts ox join public.experts x on x.id = ox.expert_id
                             where ox.organization_id = v_org and x.status_experts = ''suspendu''), ''[]''::jsonb),');
  execute d;
end $mig$;
