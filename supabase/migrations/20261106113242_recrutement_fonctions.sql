create or replace function public.recruitment_expert_stats(p_expert_id uuid, p_start date default null, p_end date default null, p_type text default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare v_user uuid; t0 timestamptz := coalesce(p_start, '2000-01-01')::timestamptz; t1 timestamptz := (coalesce(p_end, current_date) + 1)::timestamptz;
        v_months numeric; v jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select user_id into v_user from public.experts where id = p_expert_id;
  select greatest(1, extract(epoch from (t1 - greatest(t0, min(r.submitted_at)))) / (86400 * 30.44)) into v_months
    from public.rdf_reports r where r.created_by = v_user;
  with rep as (
    select r.*, m.mandate_type::text mt, m.started_at
      from public.rdf_reports r join public.mandates m on m.id = r.mandate_id
     where r.created_by = v_user and r.status in ('submitted','validated','completed')
       and r.submitted_at >= t0 and r.submitted_at < t1
       and (p_type is null or m.mandate_type::text = p_type))
  select jsonb_build_object(
    'nb_visio', (select count(*) from rep where mt = 'visio'),
    'nb_rdf',   (select count(*) from rep where mt = 'rdf'),
    'nb_rdfs',  (select count(*) from rep where mt = 'rdfs'),
    'duree_rdf',  (select round(avg(extract(epoch from submitted_at - started_at) / 60)::numeric) from rep where mt = 'rdf' and started_at is not null),
    'duree_rdfs', (select round(avg(extract(epoch from submitted_at - started_at) / 60)::numeric) from rep where mt = 'rdfs' and started_at is not null),
    'duree_visio',(select round(avg(extract(epoch from submitted_at - started_at) / 60)::numeric) from rep where mt = 'visio' and started_at is not null),
    'rdf_mois',  round((select count(*) from rep where mt = 'rdf') / coalesce(v_months, 1), 1),
    'rdfs_mois', round((select count(*) from rep where mt = 'rdfs') / coalesce(v_months, 1), 1),
    'note_client', (select rating from public.experts where id = p_expert_id),
    'reactivite_min', (select round(avg_response_time_min) from public.expert_kpis where expert_id = p_expert_id),
    'non_collecte', jsonb_build_array('Respect des créneaux horaires', 'Complétude des dossiers', 'Temps moyen d''arrivée à domicile',
                                      'Note assurance moyenne', 'Valeur moyenne de devis', 'Note PLOMI', 'Indice de fiabilité'))
  into v;
  if p_start is not null or p_end is not null or p_type is not null then
    insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
    values (auth.uid(), 'expert', p_expert_id, 'recruitment_stats_viewed',
            jsonb_build_object('start', p_start, 'end', p_end, 'type', p_type));
  end if;
  return v;
end $$;

create or replace function public.recruitment_data()
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return jsonb_build_object(
    'last_added_at', (select max(created_at) from public.experts),
    'added_per_month', (select coalesce(jsonb_agg(jsonb_build_object('month', mo, 'count', n) order by mo desc), '[]'::jsonb)
                          from (select date_trunc('month', created_at)::date mo, count(*) n from public.experts group by 1) a),
    'non_collecte', jsonb_build_array('Respect des créneaux', 'Complétude des dossiers', 'Temps moyen d''arrivée', 'Indice de fiabilité',
                                      'Type de contrat (AE, SARL…)', 'Note assurance', 'Valeur de devis', 'Note PLOMI'),
    'experts', coalesce((select jsonb_agg(x order by x->>'company_name', x->>'last_name') from (
      select jsonb_build_object(
        'id', e.id, 'first_name', e.first_name, 'last_name', e.last_name,
        'company_id', e.organization_id, 'company_name', coalesce(o.name, e.company_name), 'logo_url', o.logo_url, 'photo_url', e.photo_url,
        'siret', coalesce(e.siret, o.siret), 'email', e.email, 'phone', e.phone,
        'address', concat_ws(' ', e.address_line_1, e.postal_code, e.city),
        'latitude', e.latitude, 'longitude', e.longitude,
        'coverage_zone', e.coverage_zone,
        'departments', (select coalesce(jsonb_agg(distinct d), '[]'::jsonb) from (
                          select (regexp_matches(coalesce(e.coverage_zone,''), '\m(\d{2}|2A|2B|97\d)\M', 'g'))[1] d
                          union select left(e.postal_code, 2) where e.postal_code ~ '^\d{5}$') dd),
        'agreements', to_jsonb(coalesce(e.agreements, '{}')),
        'is_full', coalesce(e.agreements, '{}') @> array['visio','rdf','rdfs'],
        'rating', e.rating,
        'in_base', oe.id is not null,
        'precision', s.precision_score, 'reactivite', s.reactivite_score, 'rapidite', s.rapidite_score, 'avis_client', s.avis_client_score,
        'last_activity_at', k.last_activity_at, 'created_at', e.created_at)
        || (public.recruitment_expert_stats(e.id) - 'non_collecte') as x
        from public.experts e
        left join public.organizations o on o.id = e.organization_id
        left join public.org_experts oe on oe.expert_id = e.id and oe.organization_id = v_org
        left join public.plo_expert_scores() s on s.expert_id = e.id
        left join public.expert_kpis k on k.expert_id = e.id
       where coalesce(e.status_experts::text, 'new') <> 'suspendu') q), '[]'::jsonb));
end $$;

create or replace function public.recruit_experts(p_expert_ids uuid[])
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id(); n integer;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if cardinality(coalesce(p_expert_ids, '{}')) = 0 then raise exception 'Cochez au moins un expert'; end if;
  insert into public.org_experts (organization_id, expert_id, source, added_by)
  select v_org, e.id, 'recrutement', auth.uid() from public.experts e
   where e.id = any(p_expert_ids) and coalesce(e.status_experts::text, 'new') <> 'suspendu'
  on conflict do nothing;
  get diagnostics n = row_count;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', gen_random_uuid(), 'experts_recruited',
          jsonb_build_object('selected', cardinality(p_expert_ids), 'added', n, 'expert_ids', p_expert_ids));
  return n;
end $$;

create or replace function public.log_recruitment_filters(p_filters jsonb)
 returns void language sql security definer set search_path to 'public'
as $$
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  select auth.uid(), 'broadcast', gen_random_uuid(), 'recruitment_filters', p_filters where public.is_manager();
$$;

create table if not exists public.expert_fiche_locks (
  expert_id uuid not null references public.experts(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  primary key (expert_id, organization_id));
alter table public.expert_fiche_locks enable row level security;

create or replace function public.recruitment_fiche(p_expert_id uuid)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id(); v_company uuid; v_holder text; v_lock record; v jsonb; v_all jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select organization_id into v_company from public.experts where id = p_expert_id;
  if not found then raise exception 'Expert introuvable'; end if;
  select * into v_lock from public.expert_fiche_locks where expert_id = p_expert_id and organization_id = v_org;
  if found and v_lock.user_id <> auth.uid() and v_lock.expires_at > now() then
    v_holder := public.lock_holder_name(v_lock.user_id);
  else
    insert into public.expert_fiche_locks (expert_id, organization_id, user_id, expires_at)
    values (p_expert_id, v_org, auth.uid(), now() + interval '10 minutes')
    on conflict (expert_id, organization_id) do update set user_id = excluded.user_id, expires_at = excluded.expires_at;
  end if;
  v_all := public.recruitment_data()->'experts';
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'expert', p_expert_id, 'recruitment_fiche_viewed', jsonb_build_object('locked_by', v_holder));
  select jsonb_build_object(
    'locked_by', v_holder,
    'expert_id', p_expert_id,
    'company', (select jsonb_build_object('id', o.id, 'name', o.name, 'siret', o.siret, 'logo_url', o.logo_url, 'email', o.email, 'phone', o.phone,
                       'address', concat_ws(' ', o.address_line_1, o.postal_code, o.city))
                  from public.organizations o where o.id = v_company),
    'experts', (select coalesce(jsonb_agg(x order by x->>'last_name'), '[]'::jsonb) from (
       select (select y from jsonb_array_elements(v_all) y where (y->>'id')::uuid = e.id)
              || jsonb_build_object(
                   'status', e.status_experts, 'trade_name', e.trade_name,
                   'lists', coalesce((select string_agg(l.name, ', ' order by l.name) from public.expert_list_members lm
                                       join public.expert_lists l on l.id = lm.list_id and l.organization_id = v_org
                                      where lm.expert_id = e.id), ''),
                   'nb_mandats', (select count(*) from public.mandate_assignments a join public.mandates m on m.id = a.mandate_id
                                   where a.expert_id = e.id and m.insurance_org_id = v_org)) x
         from public.experts e
        where (v_company is not null and e.organization_id = v_company or e.id = p_expert_id)
          and coalesce(e.status_experts::text, 'new') <> 'suspendu') q),
    'suggested_lists', (select coalesce(jsonb_agg(jsonb_build_object(
             'id', l.id, 'name', l.name, 'member_count', (select count(*) from public.expert_list_members m where m.list_id = l.id),
             'reason', case l.auto_rule when 'top_precision' then 'Précision' when 'top_reactivity' then 'Réactivité'
                                        when 'top_speed' then 'Rapidité' when 'top_rating' then 'Avis client'
                                        when 'confirmed' then 'Expert confirmé' when 'new_recruits' then 'Nouvelle recrue'
                                        when 'agr_visio' then 'Agrément Visio' when 'agr_rdf' then 'Agrément RDF'
                                        when 'agr_rdfs' then 'Agrément RDFS' when 'agr_full' then 'Agrément Full' else l.auto_rule end)
             order by l.name), '[]'::jsonb)
        from public.expert_lists l
       where l.organization_id = v_org and l.is_active and l.auto_rule is not null
         and p_expert_id in (select public.expert_list_rule_members(l.auto_rule)))
  ) into v;
  return v;
end $$;

create or replace function public.unlock_expert_fiche(p_expert_id uuid)
 returns void language sql security definer set search_path to 'public'
as $$ delete from public.expert_fiche_locks where expert_id = p_expert_id
        and organization_id = public.current_user_organization_id() and user_id = auth.uid() $$;

do $$ declare f text; begin
  foreach f in array array['recruitment_expert_stats(uuid,date,date,text)','recruitment_data()','recruit_experts(uuid[])',
                           'log_recruitment_filters(jsonb)','recruitment_fiche(uuid)','unlock_expert_fiche(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
