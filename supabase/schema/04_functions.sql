-- PLOMI — instantané du schéma de production (projet Supabase « PLOMI »)
-- Généré depuis le catalogue PostgreSQL. Ne pas exécuter tel quel sur une base existante.

-- ------------------------------------------------------------
-- add_experts_to_lists
CREATE OR REPLACE FUNCTION public.add_experts_to_lists(p_expert_ids uuid[], p_list_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer; v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if cardinality(coalesce(p_expert_ids,'{}')) = 0 then raise exception 'Cochez au moins un expert'; end if;
  if cardinality(coalesce(p_list_ids,'{}')) = 0 then raise exception 'Choisissez au moins une liste'; end if;
  if exists (select 1 from unnest(p_list_ids) x
              where not exists (select 1 from public.expert_lists l where l.id = x and l.organization_id = v_org)) then
    raise exception 'Liste introuvable dans votre organisation';
  end if;
  if exists (select 1 from public.expert_lists where id = any(p_list_ids) and auto_rule is not null) then
    raise exception 'Les listes automatiques (KPI, agréments) se remplissent seules et ne peuvent pas être modifiées à la main';
  end if;
  if exists (select 1 from unnest(p_expert_ids) x
              where not exists (select 1 from public.org_experts oe where oe.expert_id = x and oe.organization_id = v_org)) then
    raise exception 'Recrutez d''abord l''expert dans votre base';
  end if;
  insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
  select l.id, e.id, auth.uid()
    from public.expert_lists l cross join public.experts e
   where l.id = any(p_list_ids) and l.organization_id = v_org and e.id = any(p_expert_ids)
  on conflict (list_id, expert_id) do nothing;
  get diagnostics n = row_count;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', gen_random_uuid(), 'experts_added_to_lists',
          jsonb_build_object('expert_ids', p_expert_ids, 'list_ids', p_list_ids, 'added', n));
  return n;
end $function$
;

-- ------------------------------------------------------------
-- auto_suspend_overdue_mandates
CREATE OR REPLACE FUNCTION public.auto_suspend_overdue_mandates()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    r record;
    n integer := 0;
begin
    for r in
        select m.id
        from public.mandates m
        left join lateral (
            select a.assignment_type
            from public.mandate_assignments a
            where a.mandate_id = m.id and a.status in ('pending','accepted')
            order by a.assigned_at desc limit 1
        ) a on true
        where (m.status = 'assigned' and m.started_at is null and m.assigned_at is not null
               and now() > case
                    when a.assignment_type = 'manual' then m.assigned_at + interval '48 hours'
                    when m.selected_slot_at is not null then m.selected_slot_at + interval '30 minutes'
                    else (date_trunc('day', m.assigned_at at time zone 'Europe/Paris') + interval '1 day') at time zone 'Europe/Paris'
               end)
           or (m.status = 'in_progress' and m.started_at is not null
               and now() > m.started_at + interval '2 hours')
    loop
        perform public.transition_mandate_status(r.id, 'suspended');
        update public.mandates
           set motif_abandon = 'Suspension automatique : délai dépassé', date_abandon = now()
         where id = r.id;
        -- Attribution manuelle jamais démarrée : expirée (pénalité KPI : mandate_expired + redrop_caused)
        update public.mandate_assignments
           set status = 'expired', comment = coalesce(comment, 'Délai de 48 h dépassé sans démarrage')
         where mandate_id = r.id and status = 'pending';
        n := n + 1;
    end loop;
    return n;
end;
$function$
;

-- ------------------------------------------------------------
-- create_expert_record
CREATE OR REPLACE FUNCTION public.create_expert_record(p_manager_id uuid, p_user_id uuid, p_data jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company text := nullif(trim(p_data->>'company_name'), '');
  v_org uuid; v_id uuid; v_agr text[]; v_mgr_org uuid;
begin
  if auth.role() <> 'service_role' then raise exception 'Réservé au serveur'; end if;
  select organization_id into v_mgr_org from public.user_profiles where id = p_manager_id and role = 'gestionnaire_assurance';
  if v_mgr_org is null then raise exception 'Réservé aux gestionnaires'; end if;
  if nullif(trim(p_data->>'first_name'), '') is null or nullif(trim(p_data->>'last_name'), '') is null then
    raise exception 'Le prénom et le nom sont obligatoires';
  end if;
  if v_company is null then raise exception 'La société est obligatoire'; end if;
  select coalesce(array_agg(lower(x)), '{}') into v_agr
    from jsonb_array_elements_text(coalesce(p_data->'agreements', '[]'::jsonb)) x;
  select id into v_org from public.organizations
   where type = 'expert_company' and lower(name) = lower(v_company) limit 1;
  if v_org is null then
    insert into public.organizations (name, type, siret)
    values (v_company, 'expert_company', nullif(trim(p_data->>'siret'), ''))
    returning id into v_org;
  end if;
  update public.user_profiles
     set role = 'expert', organization_id = v_org,
         first_name = trim(p_data->>'first_name'), last_name = trim(p_data->>'last_name'),
         phone = nullif(trim(p_data->>'phone'), '')
   where id = p_user_id;
  insert into public.experts (user_id, organization_id, company_name, trade_name, siret, specialty, coverage_zone,
                              phone, email, address_line_1, address_line_2, postal_code, city,
                              first_name, last_name, agreements, status_experts)
  values (p_user_id, v_org, v_company, nullif(trim(p_data->>'trade_name'), ''), nullif(trim(p_data->>'siret'), ''),
          nullif(trim(p_data->>'specialty'), ''), nullif(trim(p_data->>'coverage_zone'), ''),
          nullif(trim(p_data->>'phone'), ''), lower(trim(p_data->>'email')),
          nullif(trim(p_data->>'address_line_1'), ''), nullif(trim(p_data->>'address_line_2'), ''),
          nullif(trim(p_data->>'postal_code'), ''), nullif(trim(p_data->>'city'), ''),
          trim(p_data->>'first_name'), trim(p_data->>'last_name'), v_agr, 'new')
  returning id into v_id;
  insert into public.expert_kpis (expert_id, user_id)
  select v_id, p_user_id where not exists (select 1 from public.expert_kpis where expert_id = v_id);
  insert into public.org_experts (organization_id, expert_id, source, added_by)
  values (v_mgr_org, v_id, 'creation', p_manager_id) on conflict do nothing;
  return v_id;
end $function$
;

-- ------------------------------------------------------------
-- current_expert_id
CREATE OR REPLACE FUNCTION public.current_expert_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select id from public.experts where user_id = auth.uid() limit 1 $function$
;

-- ------------------------------------------------------------
-- current_expert_matching_list
CREATE OR REPLACE FUNCTION public.current_expert_matching_list(p_list_ids uuid[])
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select m.list_id
    from public.expert_list_members m
    join public.experts e on e.id = m.expert_id
    join public.expert_lists l on l.id = m.list_id and coalesce(l.is_active, true)
    where e.user_id = auth.uid()
      and m.list_id = any(p_list_ids)
    order by m.added_at
    limit 1;
$function$
;

-- ------------------------------------------------------------
-- current_user_organization_id
CREATE OR REPLACE FUNCTION public.current_user_organization_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
    select organization_id
    from public.user_profiles
    where id = auth.uid()
$function$
;

-- ------------------------------------------------------------
-- current_user_role
CREATE OR REPLACE FUNCTION public.current_user_role()
 RETURNS app_role
 LANGUAGE sql
 STABLE
AS $function$
    select role
    from public.user_profiles
    where id = auth.uid()
$function$
;

-- ------------------------------------------------------------
-- delete_plo_strategy
CREATE OR REPLACE FUNCTION public.delete_plo_strategy(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  delete from public.plo_strategies where id = p_id and organization_id = public.current_user_organization_id();
  if not found then raise exception 'Stratégie introuvable (les modèles ne se suppriment pas)'; end if;
end $function$
;

-- ------------------------------------------------------------
-- drop_mandate
CREATE OR REPLACE FUNCTION public.drop_mandate(p_mandate_id uuid, p_list_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_status mandate_status;
begin
  select status into v_status from public.mandates where id = p_mandate_id;
  if not found then raise exception 'Mandat introuvable'; end if;
  if v_status in ('draft','new') then
    perform public.transition_mandate_status(p_mandate_id, 'drop_pending');
  end if;
  perform public.transition_mandate_status(p_mandate_id, 'dropped', null, null, 'manual', p_list_ids);
end $function$
;

-- ------------------------------------------------------------
-- duplicate_expert_list
CREATE OR REPLACE FUNCTION public.duplicate_expert_list(p_list_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := public.current_user_organization_id(); v_src public.expert_lists%rowtype; v_name text; n int := 1; v_id uuid;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select * into v_src from public.expert_lists where id = p_list_id and organization_id = v_org;
  if not found then raise exception 'Liste introuvable dans votre organisation'; end if;
  loop
    v_name := v_src.name || ' ' || n;
    exit when not exists (select 1 from public.expert_lists where organization_id = v_org and lower(name) = lower(v_name));
    n := n + 1;
  end loop;
  insert into public.expert_lists (organization_id, name, description, color, is_active, created_by_user_id)
  values (v_org, v_name, v_src.description, v_src.color, true, auth.uid()) returning id into v_id;
  insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
  select v_id, m.expert_id, auth.uid() from public.expert_list_members m where m.list_id = p_list_id;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', v_id, 'expert_list_duplicated', jsonb_build_object('source', p_list_id, 'list_id', v_id, 'name', v_name));
  return jsonb_build_object('id', v_id, 'name', v_name);
end $function$
;

-- ------------------------------------------------------------
-- escalate_mandate_priority
CREATE OR REPLACE FUNCTION public.escalate_mandate_priority()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  update mandates set priority = 'critical'
   where priority = 'high'   and status in ('draft','drop_pending') and created_at < now() - interval '4 hours';
  update mandates set priority = 'critical'
   where priority = 'medium' and status in ('draft','drop_pending') and created_at < now() - interval '12 hours';
  update mandates set priority = 'critical'
   where priority = 'low'    and status in ('draft','drop_pending') and created_at < now() - interval '24 hours';
end;
$function$
;

-- ------------------------------------------------------------
-- expert_abandon_mandate
CREATE OR REPLACE FUNCTION public.expert_abandon_mandate(p_mandate_id uuid, p_motif text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype;
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    if nullif(trim(coalesce(p_motif,'')), '') is null then raise exception 'Le motif d''abandon est obligatoire'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then
        raise exception 'Ce mandat ne vous est pas attribué';
    end if;
    if v_m.status not in ('assigned','in_progress') then
        raise exception 'Ce mandat ne peut plus être abandonné (statut actuel : %)', v_m.status;
    end if;
    perform public.transition_mandate_status(p_mandate_id, 'suspended', null, 'Abandon expert : ' || trim(p_motif));
    update public.mandate_assignments set status = 'refused', refused_at = now(), comment = trim(p_motif)
     where mandate_id = p_mandate_id and expert_id = v_expert and status in ('pending','accepted');
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
    values (v_expert, 'mandate_refused', p_mandate_id, jsonb_build_object('motif', trim(p_motif), 'from_status', v_m.status)),
           (v_expert, 'redrop_caused',  p_mandate_id, jsonb_build_object('reason', 'abandon'));
end;
$function$
;

-- ------------------------------------------------------------
-- expert_archive_detail
CREATE OR REPLACE FUNCTION public.expert_archive_detail(p_mandate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v_r public.rdf_reports%rowtype;
        v_org record; v_planned timestamptz; v_rooms int; v_photos int; v_words int;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  select * into v_m from public.mandates where id = p_mandate_id;
  if not found or v_m.assigned_expert_id is distinct from v_expert then raise exception 'Archive introuvable'; end if;
  select * into v_r from public.rdf_reports where mandate_id = p_mandate_id order by submitted_at desc nulls last limit 1;
  if v_r.id is null then raise exception 'Aucun rapport envoyé pour ce mandat'; end if;
  select name, logo_url into v_org from public.organizations where id = v_m.insurance_org_id;
  v_planned := coalesce(v_m.selected_slot_at, v_m.slot_1_at);
  select count(*), coalesce(sum(cardinality(photos)),0) into v_rooms, v_photos from public.rdf_report_rooms where report_id = v_r.id;
  v_words := case when trim(coalesce(v_r.rapport_conclusions,'')) = '' then 0
                  else array_length(regexp_split_to_array(trim(v_r.rapport_conclusions), '\s+'),1) end;

  insert into public.activity_logs (user_id, organization_id, entity_type, entity_id, action)
  values (auth.uid(), v_m.insurance_org_id, 'report', v_r.id, 'archive_viewed');

  return jsonb_build_object(
    'mandate_id', v_m.id, 'report_id', v_r.id, 'reference', v_m.reference, 'mandate_type', v_m.mandate_type,
    'organization', v_org.name, 'logo_url', v_org.logo_url, 'sent_at', v_r.submitted_at,
    'kpi', jsonb_build_object(
      'duree_intervention_min', case when v_m.started_at is not null and v_r.submitted_at is not null
                                     then round(extract(epoch from v_r.submitted_at - v_m.started_at)/60) end,
      'ecart_creneau_min', case when v_m.arrived_at is not null and v_planned is not null
                                then round(extract(epoch from v_m.arrived_at - v_planned)/60) end,
      'nb_pieces', v_rooms, 'nb_medias', v_photos, 'mots_conclusion', v_words,
      'nb_hypotheses', cardinality(coalesce(v_r.hypotheses,'{}'))),
    'nb_consultations', (select count(*) from public.activity_logs where entity_id = v_r.id and action = 'archive_viewed' and user_id = auth.uid()),
    'nb_envois', (select count(*) from public.activity_logs where entity_id = v_r.id and action = 'archive_sent' and user_id = auth.uid()),
    'nb_telechargements', (select count(*) from public.activity_logs where entity_id = v_r.id and action = 'archive_downloaded' and user_id = auth.uid()));
end $function$
;

-- ------------------------------------------------------------
-- expert_archives
CREATE OR REPLACE FUNCTION public.expert_archives()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id();
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  return coalesce((
    select jsonb_agg(x order by (x->>'sent_at') desc) from (
      select jsonb_build_object(
        'mandate_id', m.id, 'report_id', r.id, 'reference', m.reference,
        'mandate_type', m.mandate_type, 'status', m.status,
        'department', case when m.postal_code ~ '^97' then left(m.postal_code,3)
                           when m.postal_code ~ '^20' then (case when m.postal_code < '20200' then '2A' else '2B' end)
                           else left(m.postal_code,2) end,
        'sent_at', r.submitted_at,
        'beneficiary_first_name', b.first_name, 'beneficiary_last_name', b.last_name,
        'phone', coalesce(b.mobile_phone, b.landline_phone), 'email', b.email,
        'address', concat_ws(', ', m.address_line_1, m.address_line_2, concat_ws(' ', m.postal_code, m.city)),
        'organization', o.name, 'has_pdf', r.pdf_url is not null) x
      from public.rdf_reports r
      join public.mandates m on m.id = r.mandate_id
      left join public.beneficiaries b on b.id = m.beneficiary_id
      left join public.organizations o on o.id = m.insurance_org_id
      where m.assigned_expert_id = v_expert
        and r.submitted_at >= now() - interval '1 year'
        and r.id = (select r2.id from public.rdf_reports r2 where r2.mandate_id = m.id order by r2.submitted_at desc nulls last limit 1)
    ) s), '[]'::jsonb);
end $function$
;

-- ------------------------------------------------------------
-- expert_claim_mandate
CREATE OR REPLACE FUNCTION public.expert_claim_mandate(p_mandate_id uuid, p_selected_slot_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_expert_id  uuid;
    v_m          public.mandates%rowtype;
    v_assignment uuid;
    v_list_id    uuid;
begin
    select id into v_expert_id from public.experts where user_id = auth.uid();
    if not found then
        raise exception 'Aucun profil expert trouvé pour cet utilisateur';
    end if;

    if exists (select 1 from public.mandates
               where assigned_expert_id = v_expert_id and status in ('assigned','in_progress')) then
        raise exception 'Vous avez déjà un mandat à traiter : terminez-le avant d''en prendre un autre';
    end if;

    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then
        raise exception 'Mandat introuvable : %', p_mandate_id;
    end if;
    if v_m.status not in ('dropped','redrop') then
        raise exception 'Ce mandat n''est plus disponible (statut actuel : %)', v_m.status;
    end if;

    if cardinality(v_m.target_list_ids) > 0 then
        v_list_id := public.current_expert_matching_list(v_m.target_list_ids);
        if v_list_id is null then
            raise exception 'Ce mandat est réservé à d''autres listes d''experts';
        end if;
    end if;

    if coalesce(v_m.slot_1_at, v_m.slot_2_at, v_m.slot_3_at) is not null then
        if p_selected_slot_at is null then
            raise exception 'Veuillez choisir un créneau';
        end if;
        if p_selected_slot_at is distinct from v_m.slot_1_at
           and p_selected_slot_at is distinct from v_m.slot_2_at
           and p_selected_slot_at is distinct from v_m.slot_3_at then
            raise exception 'Créneau invalide pour ce mandat';
        end if;
    end if;

    perform public.transition_mandate_status(
        p_mandate_id, 'assigned', v_expert_id, null,
        case when v_m.status = 'redrop' then 'redrop'::assignment_type else 'automatic'::assignment_type end
    );

    update public.mandates set selected_slot_at = p_selected_slot_at where id = p_mandate_id;

    select id into v_assignment
    from public.mandate_assignments
    where mandate_id = p_mandate_id and expert_id = v_expert_id and status = 'accepted'
    order by assigned_at desc limit 1;

    if v_list_id is not null then
        update public.mandate_assignments set list_id = v_list_id where id = v_assignment;
    end if;

    return v_assignment;
end;
$function$
;

-- ------------------------------------------------------------
-- expert_delete_profile
CREATE OR REPLACE FUNCTION public.expert_delete_profile()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id();
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if exists (select 1 from public.mandates where assigned_expert_id = v_expert and status in ('assigned','in_progress','planning')) then
    raise exception 'Terminez ou abandonnez vos mandats en cours avant de supprimer votre profil';
  end if;
  delete from public.expert_list_members where expert_id = v_expert;
  delete from public.expert_profile_assignments where expert_id = v_expert;
  delete from public.org_experts where expert_id = v_expert;
  delete from public.expert_fiche_locks where expert_id = v_expert;
  delete from public.expert_kpis where expert_id = v_expert;
  delete from public.expert_performance_logs where expert_id = v_expert;
  update public.experts set first_name = 'Expert', last_name = 'supprimé', civility = null, phone = null, phone_2 = null,
         email = null, photo_url = null, address_line_1 = null, address_line_2 = null, siret = null, trade_name = null,
         latitude = null, longitude = null, rating = null, status_experts = 'suspendu', updated_at = now()
   where id = v_expert;
  update public.user_profiles set first_name = 'Expert', last_name = 'supprimé', phone = null,
         account_status = 'banned', updated_at = now()
   where id = auth.uid();
  insert into public.activity_logs (user_id, entity_type, entity_id, action) values (auth.uid(), 'user', auth.uid(), 'profile_deleted');
end $function$
;

-- ------------------------------------------------------------
-- expert_has_assignment
CREATE OR REPLACE FUNCTION public.expert_has_assignment(p_mandate_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select exists (select 1 from public.mandate_assignments
                      where mandate_id = p_mandate_id and expert_id = public.current_expert_id()) $function$
;

-- ------------------------------------------------------------
-- expert_launch_data
CREATE OR REPLACE FUNCTION public.expert_launch_data(p_mandate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v jsonb;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  select * into v_m from public.mandates where id = p_mandate_id;
  if not found then raise exception 'Mandat introuvable'; end if;
  if v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
  if v_m.arrived_at is null and v_m.status in ('assigned', 'in_progress') then
    update public.mandates set arrived_at = now() where id = p_mandate_id;
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
    values (v_expert, 'arrived_on_site', p_mandate_id,
            jsonb_build_object('planned_at', coalesce(v_m.selected_slot_at, v_m.slot_1_at)));
  end if;
  select jsonb_build_object(
    'id', m.id, 'reference', m.reference, 'mandate_type', m.mandate_type, 'status', m.status,
    'organization', o.name, 'logo_url', o.logo_url,
    'beneficiary_first_name', b.first_name, 'beneficiary_last_name', b.last_name,
    'address', concat_ws(' ', m.address_line_1, m.postal_code, m.city),
    'phone_1', b.mobile_phone, 'phone_2', b.landline_phone, 'email', b.email,
    'description', coalesce(nullif(m.symptoms, ''), nullif(m.comments, ''), m.description),
    'floor', m.floor, 'entry_code', m.entry_code,
    'planned_at', coalesce(m.selected_slot_at, m.slot_1_at),
    'arrived_at', m.arrived_at, 'started_at', m.started_at)
    into v
    from public.mandates m
    left join public.beneficiaries b on b.id = m.beneficiary_id
    left join public.organizations o on o.id = m.insurance_org_id
   where m.id = p_mandate_id;
  return v;
end $function$
;

-- ------------------------------------------------------------
-- expert_list_rule_members
CREATE OR REPLACE FUNCTION public.expert_list_rule_members(p_rule text)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with k as (
    select e.id, lower(coalesce(e.agreements,'{}'::text[])::text)::text[] as agr, e.rating,
           coalesce(k.reports_submitted,0) as rdf,
           nullif(k.avg_response_time_min,0) as reac,
           nullif(k.avg_intervention_duration_min,0) as speed
      from public.experts e left join public.expert_kpis k on k.expert_id = e.id
  ),
  prec as (
    select e.id,
           avg(coalesce(ph.n,0) + coalesce(cardinality(r.inspection_photos),0)) as photos,
           avg(coalesce(length(r.rapport_conclusions),0) + coalesce(length(r.inspection_commentaires),0) + coalesce(ph.c,0)) as chars
      from public.rdf_reports r
      join public.experts e on e.user_id = r.created_by
      left join lateral (select sum(coalesce(cardinality(rr.photos),0)) n, sum(coalesce(length(rr.commentaire),0)) c
                           from public.rdf_report_rooms rr where rr.report_id = r.id) ph on true
     where r.status in ('submitted','validated','completed')
     group by e.id
  ),
  scored as (
    select 'top_reactivity' rule, id, reac  as v, true  asc_ from k where reac is not null
    union all select 'top_speed',  id, speed, true  from k where speed is not null
    union all select 'top_rating', id, rating, false from k where rating is not null
    union all select 'top_precision', id,
           ((percent_rank() over (order by photos) + percent_rank() over (order by chars)) / 2)::numeric, false from prec
  ),
  ranked as (
    select id, rank() over (order by case when asc_ then v end asc, case when not asc_ then v end desc) rn,
           count(*) over () n
      from scored where rule = p_rule
  )
  select id from k where
       (p_rule = 'new_recruits' and rdf < 3)
    or (p_rule = 'confirmed'    and rdf > 20 and coalesce(rating,0) >= 4)
    or (p_rule = 'agr_visio'    and 'visio' = any(agr))
    or (p_rule = 'agr_rdf'      and 'rdf'   = any(agr))
    or (p_rule = 'agr_rdfs'     and 'rdfs'  = any(agr))
    or (p_rule = 'agr_full'     and agr @> array['visio','rdf','rdfs'])
  union
  select id from ranked where p_rule like 'top_%' and rn <= greatest(1, ceil(n * 0.2))
$function$
;

-- ------------------------------------------------------------
-- expert_lists_page_data
CREATE OR REPLACE FUNCTION public.expert_lists_page_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return jsonb_build_object(
    'lists', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'name', l.name, 'description', l.description, 'color', l.color,
               'auto_rule', l.auto_rule, 'is_auto', l.auto_rule is not null,
               'member_ids', coalesce((select jsonb_agg(m.expert_id) from public.expert_list_members m where m.list_id = l.id), '[]'::jsonb),
               'member_count', (select count(*) from public.expert_list_members m where m.list_id = l.id))
             order by l.auto_rule is not null, l.name)
        from public.expert_lists l where l.organization_id = v_org and l.is_active), '[]'::jsonb),
    'experts', public.manual_assignment_data(array['00000000-0000-0000-0000-000000000000']::uuid[])->'experts');
end $function$
;

-- ------------------------------------------------------------
-- expert_media_check
CREATE OR REPLACE FUNCTION public.expert_media_check(p_mandate_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  select * into v_m from public.mandates where id = p_mandate_id;
  if not found or v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
  if v_m.status <> 'in_progress' then raise exception 'Les médias ne peuvent être ajoutés que pendant l''intervention'; end if;
  return v_expert;
end $function$
;

-- ------------------------------------------------------------
-- expert_media_delete
CREATE OR REPLACE FUNCTION public.expert_media_delete(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_src public.report_media%rowtype;
begin
  select * into v_src from public.report_media where id = p_id;
  if not found then raise exception 'Média introuvable'; end if;
  perform public.expert_media_check(v_src.mandate_id);
  delete from public.report_media where id = p_id and expert_id = public.current_expert_id();
end $function$
;

-- ------------------------------------------------------------
-- expert_media_duplicate
CREATE OR REPLACE FUNCTION public.expert_media_duplicate(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_src public.report_media%rowtype; v_row public.report_media%rowtype;
begin
  select * into v_src from public.report_media where id = p_id;
  if not found then raise exception 'Média introuvable'; end if;
  perform public.expert_media_check(v_src.mandate_id);
  if v_src.expert_id <> public.current_expert_id() then raise exception 'Média introuvable'; end if;
  insert into public.report_media (mandate_id, expert_id, step, room, file_url, media_type, comment, duplicated_from)
  values (v_src.mandate_id, v_src.expert_id, v_src.step, v_src.room, v_src.file_url, v_src.media_type, v_src.comment, v_src.id)
  returning * into v_row;
  return to_jsonb(v_row);
end $function$
;

-- ------------------------------------------------------------
-- expert_media_list
CREATE OR REPLACE FUNCTION public.expert_media_list(p_mandate_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb)
    from public.report_media r where r.mandate_id = p_mandate_id and r.expert_id = public.current_expert_id();
$function$
;

-- ------------------------------------------------------------
-- expert_media_save
CREATE OR REPLACE FUNCTION public.expert_media_save(p_id uuid, p_mandate_id uuid, p_file_url text, p_media_type text, p_comment text DEFAULT NULL::text, p_annex_title text DEFAULT NULL::text, p_target_x numeric DEFAULT NULL::numeric, p_target_y numeric DEFAULT NULL::numeric, p_step smallint DEFAULT NULL::smallint, p_room text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.expert_media_check(p_mandate_id); v_row public.report_media%rowtype;
begin
  if p_id is null then
    if coalesce(p_file_url,'') !~ ('/documents/rapports/' || p_mandate_id::text || '/') then
      raise exception 'Fichier non rattaché à ce mandat'; end if;
    insert into public.report_media (mandate_id, expert_id, step, room, file_url, media_type, comment, annex_title, target_x, target_y)
    values (p_mandate_id, v_expert, p_step, nullif(trim(p_room),''), p_file_url,
            case when p_media_type in ('photo','video') then p_media_type
                 when p_media_type like 'video/%' then 'video' else 'photo' end,
            nullif(trim(p_comment),''), nullif(trim(p_annex_title),''), p_target_x, p_target_y)
    returning * into v_row;
  else
    update public.report_media set comment = nullif(trim(p_comment),''), annex_title = nullif(trim(p_annex_title),''),
           target_x = p_target_x, target_y = p_target_y,
           step = coalesce(p_step, step), room = coalesce(nullif(trim(p_room),''), room), updated_at = now()
     where id = p_id and expert_id = v_expert and mandate_id = p_mandate_id
    returning * into v_row;
    if v_row.id is null then raise exception 'Média introuvable'; end if;
  end if;
  return to_jsonb(v_row);
end $function$
;

-- ------------------------------------------------------------
-- expert_profile_data
CREATE OR REPLACE FUNCTION public.expert_profile_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); e public.experts%rowtype; s record;
        v_cre numeric; v_axes jsonb := '[]'::jsonb;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  select * into e from public.experts where id = v_expert;
  select * into s from public.plo_expert_scores() p where p.expert_id = v_expert;
  select round(100.0 * count(*) filter (where m.arrived_at <= coalesce(m.selected_slot_at, m.slot_1_at) + interval '15 minutes') / nullif(count(*),0))
    into v_cre
    from public.mandates m
   where m.assigned_expert_id = v_expert and m.arrived_at is not null and coalesce(m.selected_slot_at, m.slot_1_at) is not null;

  if s.precision_score is not null and s.precision_score < 50 then
    v_axes := v_axes || jsonb_build_array('Précision : ajoutez plus de photos par pièce et détaillez commentaires et conclusions.'); end if;
  if s.reactivite_score is not null and s.reactivite_score < 50 then
    v_axes := v_axes || jsonb_build_array('Réactivité : positionnez-vous plus rapidement sur les nouveaux mandats.'); end if;
  if s.rapidite_score is not null and s.rapidite_score < 50 then
    v_axes := v_axes || jsonb_build_array('Rapidité : réduisez le délai entre le lancement de l''intervention et l''envoi du rapport.'); end if;
  if v_cre is not null and v_cre < 50 then
    v_axes := v_axes || jsonb_build_array('Respect des créneaux : arrivez au plus tard 15 minutes après le créneau prévu.'); end if;

  return jsonb_build_object(
    'civility', e.civility, 'contract_type', e.contract_type, 'first_name', e.first_name, 'last_name', e.last_name,
    'company_name', e.company_name, 'address_line_1', e.address_line_1, 'address_line_2', e.address_line_2,
    'postal_code', e.postal_code, 'city', e.city,
    'address', concat_ws(', ', e.address_line_1, e.address_line_2, concat_ws(' ', e.postal_code, e.city)),
    'phone', e.phone, 'phone_2', e.phone_2,
    'email', coalesce((select email from auth.users where id = auth.uid()), e.email),
    'photo_url', e.photo_url,
    'rapidite', s.rapidite_score, 'reactivite', s.reactivite_score, 'precision', s.precision_score, 'respect_creneaux', v_cre,
    'axes', v_axes,
    'nb_telechargements', (select count(*) from public.activity_logs where user_id = auth.uid() and action = 'stats_report_downloaded'),
    'nb_modifications', (select count(*) from public.activity_logs where user_id = auth.uid() and action = 'profile_updated'));
end $function$
;

-- ------------------------------------------------------------
-- expert_quality_stats
CREATE OR REPLACE FUNCTION public.expert_quality_stats(p_expert_id uuid, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t0 timestamptz := coalesce(p_start, '2000-01-01'); t1 timestamptz := coalesce(p_end, now());
        v_user uuid; v jsonb; s0 timestamptz; v_days int; f numeric[]; x numeric;
        n_ass int; n_ref int; n_abd int; n_susp int; n_rep int; n_rej int; n_comp int; n_delai int; n_delai_ok int; v_cre numeric;
begin
  select user_id into v_user from public.experts where id = p_expert_id;
  select count(*), count(*) filter (where refused_at is not null) into n_ass, n_ref
    from public.mandate_assignments where expert_id = p_expert_id and assigned_at >= t0 and assigned_at < t1;
  select count(*) filter (where coalesce(l.new_values_json->>'motif', l.new_values_json->>'comment','') ilike 'Abandon expert%'),
         count(*)
    into n_abd, n_susp
    from public.activity_logs l
   where l.entity_type = 'mandate' and l.action = 'status_transition' and l.new_values_json->>'status' = 'suspended'
     and l.created_at >= t0 and l.created_at < t1
     and exists (select 1 from public.mandate_assignments a where a.mandate_id = l.entity_id and a.expert_id = p_expert_id);
  select count(*), count(*) filter (where r.rejected_at is not null), count(*) filter (where public.report_is_complete(r.id)),
         count(*) filter (where m.started_at is not null),
         count(*) filter (where m.started_at is not null and r.submitted_at <= m.started_at + interval '2 hours')
    into n_rep, n_rej, n_comp, n_delai, n_delai_ok
    from public.rdf_reports r join public.mandates m on m.id = r.mandate_id
   where r.created_by = v_user and r.submitted_at is not null and r.submitted_at >= t0 and r.submitted_at < t1;
  select round(100.0 * count(*) filter (where m.arrived_at <= coalesce(m.selected_slot_at, m.slot_1_at) + interval '15 minutes') / nullif(count(*),0))
    into v_cre from public.mandates m
   where m.assigned_expert_id = p_expert_id and m.arrived_at is not null and coalesce(m.selected_slot_at, m.slot_1_at) is not null
     and m.arrived_at >= t0 and m.arrived_at < t1;

  f := array[
    case when n_ass > 0 then 100.0 * (1 - n_ref::numeric / n_ass) end,             -- attributions acceptées
    case when n_ass > 0 then greatest(0, 100.0 * (1 - n_abd::numeric / n_ass)) end, -- pas d'abandon
    case when n_ass > 0 then greatest(0, 100.0 * (1 - n_susp::numeric / n_ass)) end,-- pas de suspension
    v_cre,                                                                          -- respect des créneaux
    case when n_rep > 0 then 100.0 * (1 - n_rej::numeric / n_rep) end,              -- rapports non refusés
    case when n_rep > 0 then 100.0 * n_comp / n_rep end,                            -- complétude
    case when n_delai > 0 then 100.0 * n_delai_ok / n_delai end];                   -- rapport envoyé sous 2 h
  select round(avg(y)) into x from unnest(f) y where y is not null;

  -- sessions (conservées 1 mois)
  s0 := greatest(t0, now() - interval '31 days');
  v_days := greatest(1, ceil(extract(epoch from (least(t1, now()) - s0)) / 86400));
  v := jsonb_build_object(
    'completude', case when n_rep > 0 then round(100.0 * n_comp / n_rep) end,
    'fiabilite', x,
    'fiabilite_detail', jsonb_build_object('attributions_acceptees', round(f[1]), 'sans_abandon', round(f[2]), 'sans_suspension', round(f[3]),
                          'respect_creneaux', round(f[4]), 'rapports_acceptes', round(f[5]), 'completude', round(f[6]), 'envoi_sous_2h', round(f[7])),
    'temps_app_h', (select round(sum(extract(epoch from (least(last_seen_at, t1) - greatest(started_at, s0)))) / 3600.0, 1)
                      from public.user_sessions where user_id = v_user and last_seen_at > s0 and started_at < t1),
    'amplitude_h', (select round(avg(extract(epoch from (fin - debut)) / 3600.0), 1) from (
                      select date_trunc('day', started_at) j, min(started_at) debut, max(last_seen_at) fin
                        from public.user_sessions where user_id = v_user and last_seen_at > s0 and started_at < t1 group by 1) d),
    'disponibilite', (select round(100.0 * count(distinct date_trunc('day', started_at)) / v_days)
                        from public.user_sessions where user_id = v_user and last_seen_at > s0 and started_at < t1));
  if not exists (select 1 from public.user_sessions where user_id = v_user and last_seen_at > s0 and started_at < t1) then
    v := v || jsonb_build_object('temps_app_h', null, 'amplitude_h', null, 'disponibilite', null);
  end if;
  return v;
end $function$
;

-- ------------------------------------------------------------
-- expert_quit_intervention
CREATE OR REPLACE FUNCTION public.expert_quit_intervention(p_mandate_id uuid, p_motif text, p_details text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_motif text := trim(coalesce(p_motif, '')); v_full text; v_m public.mandates%rowtype; v_expert_name text;
begin
  if v_motif not in ('Urgence médicale', 'Altercation client', 'Risque de blessure grave', 'Insalubrité') then
    raise exception 'Choisissez un motif d''interruption';
  end if;
  v_full := v_motif || coalesce(' — ' || nullif(trim(coalesce(p_details, '')), ''), '');
  perform public.expert_abandon_mandate(p_mandate_id, v_full);
  select * into v_m from public.mandates where id = p_mandate_id;
  select trim(concat_ws(' ', first_name, last_name)) into v_expert_name from public.experts where id = public.current_expert_id();
  insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
  select up.id, p_mandate_id, 'status_change', 'Anomalie : intervention interrompue',
         'Mandat ' || coalesce(v_m.reference, '') || ' interrompu par ' || coalesce(v_expert_name, 'l''expert') || ' : ' || v_full,
         'in_app', false, now(), 'mandate', p_mandate_id, 'mandate_details'
    from public.user_profiles up
   where up.organization_id = v_m.insurance_org_id and up.role = 'gestionnaire_assurance';
end $function$
;

-- ------------------------------------------------------------
-- expert_send_report
CREATE OR REPLACE FUNCTION public.expert_send_report(p_mandate_id uuid, p_conclusion text, p_rooms jsonb, p_hypotheses text[] DEFAULT NULL::text[], p_preconisations text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v_report uuid; r jsonb; v_pos int := 0;
        v_hyp text[];
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
    if v_m.status <> 'in_progress' then
        raise exception 'Le rapport ne peut être envoyé que pour un mandat en cours (statut actuel : %)', v_m.status;
    end if;
    if v_m.mandate_type::text <> 'visio' and (p_rooms is null or jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) = 0) then
        raise exception 'Ajoutez au moins une pièce investiguée avant d''envoyer le rapport';
    end if;

    -- hypothèses : on ne garde que les lignes renseignées
    select coalesce(array_agg(trim(h)), '{}') into v_hyp
      from unnest(coalesce(p_hypotheses, '{}')) h where nullif(trim(h), '') is not null;

    insert into public.rdf_reports (mandate_id, created_by, rapport_conclusions, hypotheses, preconisations_reserves, status, submitted_at)
    values (p_mandate_id, auth.uid(), nullif(trim(coalesce(p_conclusion,'')),''), v_hyp,
            nullif(trim(coalesce(p_preconisations,'')),''), 'submitted', now())
    returning id into v_report;

    if v_m.mandate_type::text = 'visio' and nullif(trim(coalesce(p_conclusion,'')),'') is null then
        raise exception 'La conclusion est obligatoire pour une visio expertise';
    end if;
    for r in select * from jsonb_array_elements(coalesce(p_rooms, '[]'::jsonb)) loop
        v_pos := v_pos + 1;
        if nullif(trim(coalesce(r->>'room','')),'') is null then raise exception 'Pièce manquante (ligne %)', v_pos; end if;
        insert into public.rdf_report_rooms (report_id, mandate_id, step, position, room, wall, matiere, infiltration,
            moisissure, peinture_endommagee, gaz_detecte, sonde_type, sonde_percent, commentaire, photos)
        values (v_report, p_mandate_id, (r->>'step')::smallint, v_pos, r->>'room', nullif(r->>'wall',''), nullif(r->>'matiere',''),
            (r->>'infiltration')::boolean, (r->>'moisissure')::boolean, (r->>'peinture')::boolean, (r->>'gaz_detecte')::boolean,
            nullif(r->>'sonde_type',''), nullif(replace(replace(r->>'sonde_percent','%',''),',','.'),'')::numeric,
            nullif(r->>'commentaire',''),
            coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(r->'photos','[]'::jsonb)) x), '{}'));
    end loop;

    perform public.transition_mandate_status(p_mandate_id, 'waiting_report');
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
    values (v_expert, 'report_submitted', p_mandate_id,
            jsonb_build_object('report_id', v_report, 'rooms', jsonb_array_length(p_rooms), 'hypotheses', cardinality(v_hyp)));
    return v_report;
end;
$function$
;

-- ------------------------------------------------------------
-- expert_start_mandate
CREATE OR REPLACE FUNCTION public.expert_start_mandate(p_mandate_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype;
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then
        raise exception 'Ce mandat ne vous est pas attribué';
    end if;
    if v_m.status <> 'assigned' then
        raise exception 'Le rapport ne peut être démarré que pour un mandat attribué (statut actuel : %)', v_m.status;
    end if;
    perform public.transition_mandate_status(p_mandate_id, 'in_progress');
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id)
    values (v_expert, 'intervention_started', p_mandate_id);
end;
$function$
;

-- ------------------------------------------------------------
-- expert_submit_report
CREATE OR REPLACE FUNCTION public.expert_submit_report(p_mandate_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v_report uuid;
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then
        raise exception 'Ce mandat ne vous est pas attribué';
    end if;
    if v_m.status <> 'in_progress' then
        raise exception 'Le rapport ne peut être envoyé que pour un mandat en cours (statut actuel : %)', v_m.status;
    end if;
    select id into v_report from public.rdf_reports
     where mandate_id = p_mandate_id and created_by = auth.uid() and coalesce(status,'draft') = 'draft'
     order by created_at desc limit 1;
    if v_report is null then raise exception 'Aucun rapport enregistré pour ce mandat'; end if;

    update public.rdf_reports set status = 'submitted', submitted_at = now() where id = v_report;
    perform public.transition_mandate_status(p_mandate_id, 'waiting_report');
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
    values (v_expert, 'report_submitted', p_mandate_id, jsonb_build_object('report_id', v_report));
end;
$function$
;

-- ------------------------------------------------------------
-- expert_update_profile
CREATE OR REPLACE FUNCTION public.expert_update_profile(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_old jsonb; v_new jsonb;
        f text; v text;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  foreach f in array array['first_name','last_name','company_name','address_line_1','postal_code','city','phone'] loop
    if p_data ? f and nullif(trim(coalesce(p_data->>f,'')),'') is null then
      raise exception 'Champ obligatoire manquant : %', f; end if;
  end loop;
  if p_data ? 'civility' and nullif(p_data->>'civility','') is not null and p_data->>'civility' not in ('M.','Mme') then
    raise exception 'Civilité invalide'; end if;
  if p_data ? 'contract_type' and nullif(p_data->>'contract_type','') is not null
     and p_data->>'contract_type' not in ('AE','EI','EURL','SARL','SAS','SASU','SA','Autre') then
    raise exception 'Type de contrat invalide'; end if;
  if p_data ? 'postal_code' and (p_data->>'postal_code') !~ '^[0-9]{5}$' then raise exception 'Code postal invalide (5 chiffres)'; end if;
  foreach f in array array['phone','phone_2'] loop
    v := regexp_replace(coalesce(p_data->>f,''), '[^0-9+]', '', 'g');
    if p_data ? f and v <> '' and v !~ '^(\+33|0)[1-9][0-9]{8}$' then raise exception 'Numéro de téléphone invalide : %', p_data->>f; end if;
  end loop;

  select to_jsonb(x) into v_old from (select civility, first_name, last_name, company_name, address_line_1, address_line_2, postal_code, city, phone, phone_2, contract_type from public.experts where id = v_expert) x;

  update public.experts set
    civility       = case when p_data ? 'civility' then nullif(p_data->>'civility','') else civility end,
    first_name     = case when p_data ? 'first_name' then trim(p_data->>'first_name') else first_name end,
    last_name      = case when p_data ? 'last_name' then trim(p_data->>'last_name') else last_name end,
    company_name   = case when p_data ? 'company_name' then trim(p_data->>'company_name') else company_name end,
    address_line_1 = case when p_data ? 'address_line_1' then trim(p_data->>'address_line_1') else address_line_1 end,
    address_line_2 = case when p_data ? 'address_line_2' then nullif(trim(p_data->>'address_line_2'),'') else address_line_2 end,
    postal_code    = case when p_data ? 'postal_code' then p_data->>'postal_code' else postal_code end,
    city           = case when p_data ? 'city' then trim(p_data->>'city') else city end,
    phone          = case when p_data ? 'phone' then trim(p_data->>'phone') else phone end,
    phone_2        = case when p_data ? 'phone_2' then nullif(trim(p_data->>'phone_2'),'') else phone_2 end,
    contract_type  = case when p_data ? 'contract_type' then nullif(p_data->>'contract_type','') else contract_type end,
    updated_at = now()
  where id = v_expert;

  update public.user_profiles set
    first_name = coalesce(nullif(trim(p_data->>'first_name'),''), first_name),
    last_name  = coalesce(nullif(trim(p_data->>'last_name'),''), last_name),
    phone      = coalesce(nullif(trim(p_data->>'phone'),''), phone),
    updated_at = now()
  where id = auth.uid();

  select to_jsonb(x) into v_new from (select civility, first_name, last_name, company_name, address_line_1, address_line_2, postal_code, city, phone, phone_2, contract_type from public.experts where id = v_expert) x;
  if v_new is distinct from v_old then
    insert into public.activity_logs (user_id, entity_type, entity_id, action, old_values_json, new_values_json)
    values (auth.uid(), 'user', auth.uid(), 'profile_updated', v_old, v_new);
  end if;
  return v_new;
end $function$
;

-- ------------------------------------------------------------
-- force_manager_org
CREATE OR REPLACE FUNCTION public.force_manager_org()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if public.is_manager() then
    if tg_table_name = 'mandates' then
      new.insurance_org_id := public.current_user_organization_id();
    else
      new.organization_id := public.current_user_organization_id();
    end if;
  end if;
  return new;
end $function$
;

-- ------------------------------------------------------------
-- generate_mandate_reference
CREATE OR REPLACE FUNCTION public.generate_mandate_reference()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.reference := 'MAN-' || LPAD(nextval('mandate_reference_seq')::text, 4, '0');
  RETURN NEW;
END;
$function$
;

-- ------------------------------------------------------------
-- get_complete_schema
CREATE OR REPLACE FUNCTION public.get_complete_schema()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    result jsonb;
BEGIN
    -- Get all enums
    WITH enum_types AS (
        SELECT 
            t.typname as enum_name,
            array_agg(e.enumlabel ORDER BY e.enumsortorder) as enum_values
        FROM pg_type t
        JOIN pg_enum e ON t.oid = e.enumtypid
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
        GROUP BY t.typname
    )
    SELECT jsonb_build_object(
        'enums',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'name', enum_name,
                    'values', to_jsonb(enum_values)
                )
            ),
            '[]'::jsonb
        )
    )
    FROM enum_types
    INTO result;

    -- Get all tables with their details
    WITH RECURSIVE 
    columns_info AS (
        SELECT 
            c.oid as table_oid,
            c.relname as table_name,
            a.attname as column_name,
            format_type(a.atttypid, a.atttypmod) as column_type,
            a.attnotnull as notnull,
            pg_get_expr(d.adbin, d.adrelid) as column_default,
            CASE 
                WHEN a.attidentity != '' THEN true
                WHEN pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval%' THEN true
                ELSE false
            END as is_identity,
            EXISTS (
                SELECT 1 FROM pg_constraint con 
                WHERE con.conrelid = c.oid 
                AND con.contype = 'p' 
                AND a.attnum = ANY(con.conkey)
            ) as is_pk
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_attribute a ON a.attrelid = c.oid
        LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
        WHERE n.nspname = 'public' 
        AND c.relkind = 'r'
        AND a.attnum > 0 
        AND NOT a.attisdropped
    ),
    fk_info AS (
        SELECT 
            c.oid as table_oid,
            jsonb_agg(
                jsonb_build_object(
                    'name', con.conname,
                    'column', col.attname,
                    'foreign_schema', fs.nspname,
                    'foreign_table', ft.relname,
                    'foreign_column', fcol.attname,
                    'on_delete', CASE con.confdeltype
                        WHEN 'a' THEN 'NO ACTION'
                        WHEN 'c' THEN 'CASCADE'
                        WHEN 'r' THEN 'RESTRICT'
                        WHEN 'n' THEN 'SET NULL'
                        WHEN 'd' THEN 'SET DEFAULT'
                        ELSE NULL
                    END
                )
            ) as foreign_keys
        FROM pg_class c
        JOIN pg_constraint con ON con.conrelid = c.oid
        JOIN pg_attribute col ON col.attrelid = con.conrelid AND col.attnum = ANY(con.conkey)
        JOIN pg_class ft ON ft.oid = con.confrelid
        JOIN pg_namespace fs ON fs.oid = ft.relnamespace
        JOIN pg_attribute fcol ON fcol.attrelid = con.confrelid AND fcol.attnum = ANY(con.confkey)
        WHERE con.contype = 'f'
        GROUP BY c.oid
    ),
    index_info AS (
        SELECT 
            c.oid as table_oid,
            jsonb_agg(
                jsonb_build_object(
                    'name', i.relname,
                    'using', am.amname,
                    'columns', (
                        SELECT jsonb_agg(a.attname ORDER BY array_position(ix.indkey, a.attnum))
                        FROM unnest(ix.indkey) WITH ORDINALITY as u(attnum, ord)
                        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = u.attnum
                    )
                )
            ) as indexes
        FROM pg_class c
        JOIN pg_index ix ON ix.indrelid = c.oid
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_am am ON am.oid = i.relam
        WHERE NOT ix.indisprimary
        GROUP BY c.oid
    ),
    policy_info AS (
        SELECT 
            c.oid as table_oid,
            jsonb_agg(
                jsonb_build_object(
                    'name', pol.polname,
                    'command', CASE pol.polcmd
                        WHEN 'r' THEN 'SELECT'
                        WHEN 'a' THEN 'INSERT'
                        WHEN 'w' THEN 'UPDATE'
                        WHEN 'd' THEN 'DELETE'
                        WHEN '*' THEN 'ALL'
                    END,
                    'roles', (
                        SELECT string_agg(quote_ident(r.rolname), ', ')
                        FROM pg_roles r
                        WHERE r.oid = ANY(pol.polroles)
                    ),
                    'using', pg_get_expr(pol.polqual, pol.polrelid),
                    'check', pg_get_expr(pol.polwithcheck, pol.polrelid)
                )
            ) as policies
        FROM pg_class c
        JOIN pg_policy pol ON pol.polrelid = c.oid
        GROUP BY c.oid
    ),
    trigger_info AS (
        SELECT 
            c.oid as table_oid,
            jsonb_agg(
                jsonb_build_object(
                    'name', t.tgname,
                    'timing', CASE 
                        WHEN t.tgtype & 2 = 2 THEN 'BEFORE'
                        WHEN t.tgtype & 4 = 4 THEN 'AFTER'
                        WHEN t.tgtype & 64 = 64 THEN 'INSTEAD OF'
                    END,
                    'events', (
                        CASE WHEN t.tgtype & 1 = 1 THEN 'INSERT'
                             WHEN t.tgtype & 8 = 8 THEN 'DELETE'
                             WHEN t.tgtype & 16 = 16 THEN 'UPDATE'
                             WHEN t.tgtype & 32 = 32 THEN 'TRUNCATE'
                        END
                    ),
                    'statement', pg_get_triggerdef(t.oid)
                )
            ) as triggers
        FROM pg_class c
        JOIN pg_trigger t ON t.tgrelid = c.oid
        WHERE NOT t.tgisinternal
        GROUP BY c.oid
    ),
    table_info AS (
        SELECT DISTINCT 
            c.table_oid,
            c.table_name,
            jsonb_agg(
                jsonb_build_object(
                    'name', c.column_name,
                    'type', c.column_type,
                    'notnull', c.notnull,
                    'default', c.column_default,
                    'identity', c.is_identity,
                    'is_pk', c.is_pk
                ) ORDER BY c.column_name
            ) as columns,
            COALESCE(fk.foreign_keys, '[]'::jsonb) as foreign_keys,
            COALESCE(i.indexes, '[]'::jsonb) as indexes,
            COALESCE(p.policies, '[]'::jsonb) as policies,
            COALESCE(t.triggers, '[]'::jsonb) as triggers
        FROM columns_info c
        LEFT JOIN fk_info fk ON fk.table_oid = c.table_oid
        LEFT JOIN index_info i ON i.table_oid = c.table_oid
        LEFT JOIN policy_info p ON p.table_oid = c.table_oid
        LEFT JOIN trigger_info t ON t.table_oid = c.table_oid
        GROUP BY c.table_oid, c.table_name, fk.foreign_keys, i.indexes, p.policies, t.triggers
    )
    SELECT result || jsonb_build_object(
        'tables',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'name', table_name,
                    'columns', columns,
                    'foreign_keys', foreign_keys,
                    'indexes', indexes,
                    'policies', policies,
                    'triggers', triggers
                )
            ),
            '[]'::jsonb
        )
    )
    FROM table_info
    INTO result;

    -- Get all functions
    WITH function_info AS (
        SELECT 
            p.proname AS name,
            pg_get_functiondef(p.oid) AS definition
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
        AND p.prokind = 'f'
    )
    SELECT result || jsonb_build_object(
        'functions',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'name', name,
                    'definition', definition
                )
            ),
            '[]'::jsonb
        )
    )
    FROM function_info
    INTO result;

    RETURN result;
END;
$function$
;

-- ------------------------------------------------------------
-- get_experts_by_profile
CREATE OR REPLACE FUNCTION public.get_experts_by_profile(profile_code text)
 RETURNS TABLE(expert_id uuid, company_name text, specialty text, rating numeric, status_experts expert_status)
 LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    e.id,
    e.company_name,
    e.specialty,
    e.rating,
    e.status_experts
  FROM experts e
  INNER JOIN expert_profile_assignments epa ON e.id = epa.expert_id
  INNER JOIN expert_profiles ep ON epa.profile_id = ep.id
  WHERE ep.code = profile_code
    AND ep.is_active = true
    AND e.status_experts = 'connecte'
  ORDER BY e.rating DESC NULLS LAST;
END;
$function$
;
COMMENT ON FUNCTION get_experts_by_profile(text) IS 'Retourne les experts connectés ayant un profil spécifique (code)';

-- ------------------------------------------------------------
-- get_rapport_preview_data
CREATE OR REPLACE FUNCTION public.get_rapport_preview_data(p_mandate_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
select jsonb_build_object(
  -- Mandat
  'mandate_id', m.id,
  'mandate_reference', m.reference,
  'mandate_date', to_char(m.created_at, 'DD/MM/YYYY'),
  'mandate_description', m.description,
  'mandate_status', m.status,
  'mandate_closed_at', to_char(m.closed_at, 'DD/MM/YYYY'),
  'defect_type', m.defect_type,
  'affected_rooms', m.affected_rooms,
  'location_address', concat_ws(' ', m.address_line_1, m.postal_code, m.city),
  -- Expert (auteur du rapport, à défaut l'expert assigné)
  'expert_id', e.id,
  'expert_name', coalesce(nullif(concat_ws(' ', e.first_name, e.last_name), ''), 'N/A'),
  'expert_phone', e.phone,
  'expert_email', e.email,
  'expert_company', e.company_name,
  'expert_siret', e.siret,
  -- Bénéficiaire
  'beneficiary_name', coalesce(nullif(concat_ws(' ', b.first_name, b.last_name), ''), 'N/A'),
  'beneficiary_phone', b.mobile_phone,
  'beneficiary_email', b.email,
  -- Assurance
  'insurance_name', org.name,
  -- Rapport d'expertise (dernier rapport non brouillon, sinon le brouillon)
  'report_id', r.id,
  'report_status', r.status,
  'report_submitted_at', to_char(r.submitted_at, 'DD/MM/YYYY'),
  'report_conclusions', r.rapport_conclusions,
  'report', to_jsonb(r) - 'id' - 'mandate_id' - 'created_by',
  -- Métadonnées
  'generation_date', to_char(now(), 'DD/MM/YYYY'),
  'generation_time', to_char(now(), 'HH24:MI:SS')
)
from public.mandates m
left join lateral (
  select x.*
  from public.rdf_reports x
  where x.mandate_id = m.id
  order by (x.status = 'draft'), x.created_at desc
  limit 1
) r on true
left join public.experts e on e.id = coalesce(
  (select ex.id from public.experts ex where ex.user_id = r.created_by),
  m.assigned_expert_id
)
left join public.beneficiaries b on b.id = m.beneficiary_id
left join public.organizations org on org.id = m.insurance_org_id
where m.id = p_mandate_id;
$function$
;

-- ------------------------------------------------------------
-- handle_new_user
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    insert into public.user_profiles (
        id,
        email,
        first_name,
        last_name,
        role,
        presence_status
    )
    values (
        new.id,
        new.email,
        coalesce(new.raw_user_meta_data->>'first_name', ''),
        coalesce(new.raw_user_meta_data->>'last_name', ''),
        coalesce((new.raw_user_meta_data->>'role')::app_role, 'expert'),
        'offline'
    )
    on conflict (id) do nothing;

    return new;
end;
$function$
;

-- ------------------------------------------------------------
-- in_my_base
CREATE OR REPLACE FUNCTION public.in_my_base(p_expert_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select exists (select 1 from public.org_experts where expert_id = p_expert_id
                        and organization_id = public.current_user_organization_id()) $function$
;

-- ------------------------------------------------------------
-- increment_redrop_count
CREATE OR REPLACE FUNCTION public.increment_redrop_count()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.status = 'redrop' AND (OLD.status IS DISTINCT FROM 'redrop') THEN
    NEW.redrop_count := COALESCE(OLD.redrop_count, 0) + 1;
  END IF;
  RETURN NEW;
END;
$function$
;

-- ------------------------------------------------------------
-- is_expert
CREATE OR REPLACE FUNCTION public.is_expert()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select public.current_expert_id() is not null $function$
;

-- ------------------------------------------------------------
-- is_manager
CREATE OR REPLACE FUNCTION public.is_manager()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select exists (select 1 from public.user_profiles where id = auth.uid() and role::text = 'gestionnaire_assurance') $function$
;

-- ------------------------------------------------------------
-- kpi_catalog
CREATE OR REPLACE FUNCTION public.kpi_catalog()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select jsonb_agg(jsonb_build_object('code', c, 'label', l, 'theme', t, 'unit', u, 'scope', s, 'available', a) order by o)
  from (values
   ('temps_app','Temps passé sur l''app','Disponibilité','h','expert',true,1),
   ('amplitude_horaire','Amplitude horaire','Disponibilité','h','expert',true,2),
   ('reactivite','Temps de réactivité aux nouvelles demandes de mandats','Réactivité','min','expert',true,3),
   ('temps_deplacement','Temps de déplacement à domicile','Traitement','min','expert',true,4),
   ('temps_visio','Temps de visio','Traitement','min','expert',false,5),
   ('temps_rapport_visio','Temps de réalisation rapport (visio)','Traitement','min','expert',true,6),
   ('temps_rapport_rdf','Temps de réalisation rapport par investigations (RDF)','Traitement','min','expert',true,7),
   ('temps_rapport_rdfs','Temps de réalisation rapport (RDFS)','Traitement','min','expert',true,8),
   ('visio_jour','Nombre de visio / jour','Nombre de mandats','/j','expert',true,9),
   ('rdf_jour','Nombre de RDF / jour','Nombre de mandats','/j','expert',true,10),
   ('rdfs_jour','Nombre de RDFS / jour','Nombre de mandats','/j','expert',true,11),
   ('mots_conclusion','Nombre de mots par conclusion','Précision de rapport','mots','expert',true,12),
   ('mots_rapport','Nombre de mots par rapport','Précision de rapport','mots','expert',true,13),
   ('pieces_investiguees','Nombre de pièces investiguées','Précision de rapport','pièces','expert',true,14),
   ('redrops','Nombre de redrop de mandat','Traitement','nb','both',true,15),
   ('photos_rapport','Nombre de photos par rapport','Nombre de média','photos','expert',true,16),
   ('videos_rapport','Nombre de vidéos par rapport (RDF ; RDFS)','Nombre de média','vidéos','expert',true,17),
   ('nb_avis_client','Nombre d''avis client','Compétence et professionnalisme','nb','expert',false,18),
   ('nb_listes_affilie','Nombre de listes affiliées','Compétence et professionnalisme','nb','expert',true,19),
   ('nb_zones_affilie','Nombre de zones affiliées','Géographique','nb','expert',true,20),
   ('suspensions','Nombre de suspensions','Traitement','nb','both',true,21),
   ('note_client_min','Note client minimum','Compétence et professionnalisme','/5','expert',true,22),
   ('note_client_max','Note client maximum','Compétence et professionnalisme','/5','expert',true,23),
   ('note_client_moy','Note client moyenne','Compétence et professionnalisme','/5','expert',true,24),
   ('note_app_min','Note app minimum','Compétence et professionnalisme','/5','expert',false,25),
   ('note_app_max','Note app maximum','Compétence et professionnalisme','/5','expert',false,26),
   ('note_app_moy','Note app moyenne','Compétence et professionnalisme','/5','expert',false,27),
   ('note_mandataire_min','Note mandataire minimum','Compétence et professionnalisme','/5','expert',false,28),
   ('note_mandataire_max','Note mandataire maximum','Compétence et professionnalisme','/5','expert',false,29),
   ('note_mandataire_moy','Note mandataire moyenne','Compétence et professionnalisme','/5','expert',false,30),
   ('temps_avant_drop','Temps de gestion avant drop de mandats','Traitement','h','mandataire',true,31),
   ('temps_sur_drop','Temps de mise à disposition de mandats sur le drop','Traitement','h','both',true,32),
   ('attrib_visio','Temps avant attribution de mandats visio','Réactivité','h','both',true,33),
   ('attrib_rdf','Temps avant attribution de mandats RDF','Réactivité','h','both',true,34),
   ('attrib_rdfs','Temps avant attribution de mandats RDFS','Réactivité','h','both',true,35),
   ('traitement_visio','Temps de traitement mandats visio','Traitement','h','both',true,36),
   ('traitement_rdf','Temps de traitement mandats RDF','Traitement','h','both',true,37),
   ('traitement_rdfs','Temps de traitement mandats RDFS','Traitement','h','both',true,38),
   ('temps_reattribution','Temps de réattribution mandat (visio ; RDF ; RDFS)','Réactivité','h','mandataire',true,39),
   ('temps_suspension','Temps de suspension moyen','Traitement','h','mandataire',true,40),
   ('demandes_mois','Nombre de demandes de mandats / mois (visio ; RDF ; RDFS)','Nombre de mandats','/mois','mandataire',true,41),
   ('creation_auto','Nombre de création automatique','Nombre de mandats','nb','mandataire',true,42),
   ('creation_manuelle','Nombre de création manuelle','Nombre de mandats','nb','mandataire',true,43),
   ('redrop_rdf_apres_visio','Nombre de redrop RDF suite à visio','Nombre de mandats','nb','mandataire',false,44),
   ('redrop_rdfs_apres_rdf','Nombre de redrop RDFS suite à RDF','Nombre de mandats','nb','mandataire',false,45),
   ('experts_par_zone','Nombre d''experts par zone','Géographique','texte','mandataire',true,46),
   ('nb_listes','Nombre de listes d''experts','Compétence et professionnalisme','nb','mandataire',true,47),
   ('experts_par_liste','Nombre d''experts par liste','Compétence et professionnalisme','moy.','mandataire',true,48),
   ('clotures','Nombre de clôtures après expertise (visio ; RDF ; RDFS)','Traitement','nb','both',true,49),
   ('recrutements','Nombre de recrutement via PLOMI','Compétence et professionnalisme','nb','mandataire',true,50),
   ('disponibilite','Disponibilité (jours avec connexion, 30 derniers jours max)','Disponibilité','%','expert',true,51),
   ('respect_creneaux','Respect des créneaux (arrivée ≤ 15 min après le créneau)','Traitement','%','expert',true,52),
   ('retard_arrivee','Écart moyen d''arrivée par rapport au créneau','Traitement','min','expert',true,53),
   ('completude','Complétude des dossiers (tous les champs renseignés)','Précision de rapport','%','expert',true,54),
   ('fiabilite','Indice de fiabilité','Compétence et professionnalisme','/100','expert',true,55)
  ) v(c, l, t, u, s, a, o)
$function$
;

-- ------------------------------------------------------------
-- kpi_page_data
CREATE OR REPLACE FUNCTION public.kpi_page_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return jsonb_build_object(
    'catalog', public.kpi_catalog(),
    'favorites', coalesce((select jsonb_agg(kpi_code) from public.kpi_favorites where user_id = auth.uid()), '[]'::jsonb),
    'experts', public.manual_assignment_data(array['00000000-0000-0000-0000-000000000000']::uuid[])->'experts',
    'lists', public.expert_lists_page_data()->'lists');
end $function$
;

-- ------------------------------------------------------------
-- kpi_report
CREATE OR REPLACE FUNCTION public.kpi_report(p_start date, p_end date, p_scope text, p_expert_ids uuid[], p_kpis text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public.current_user_organization_id();
  t0 timestamptz := coalesce(p_start, current_date - 30)::timestamptz;
  t1 timestamptz := (coalesce(p_end, current_date) + 1)::timestamptz;
  v_days numeric := greatest(1, extract(epoch from (t1 - t0)) / 86400);
  v_months numeric := greatest(1, extract(epoch from (t1 - t0)) / (86400 * 30.44));
  v_rows jsonb := '[]'::jsonb; e record; v jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if t1 <= t0 then raise exception 'La date de fin doit suivre la date de début'; end if;

  if coalesce(p_scope, 'experts') = 'experts' then
    for e in select x.id, x.company_name, x.first_name, x.last_name, x.rating, x.coverage_zone
               from public.experts x where x.id = any(coalesce(p_expert_ids, '{}')) loop
      with a as (
        select ma.*, m.mandate_type, m.drop_at, m.started_at, m.closed_at, m.status
          from public.mandate_assignments ma join public.mandates m on m.id = ma.mandate_id and m.insurance_org_id = v_org
         where ma.expert_id = e.id and ma.assigned_at >= t0 and ma.assigned_at < t1),
      rep as (
        select r.*, m.mandate_type, m.started_at,
               (select count(*) from public.rdf_report_rooms rr where rr.report_id = r.id) rooms,
               coalesce((select sum(cardinality(rr.photos)) from public.rdf_report_rooms rr where rr.report_id = r.id), 0) photos,
               coalesce((select sum(array_length(regexp_split_to_array(trim(rr.commentaire), '\s+'), 1)) from public.rdf_report_rooms rr
                          where rr.report_id = r.id and nullif(trim(rr.commentaire), '') is not null), 0) room_words
          from public.rdf_reports r join public.mandates m on m.id = r.mandate_id and m.insurance_org_id = v_org
          join public.experts x on x.user_id = r.created_by and x.id = e.id
         where r.submitted_at >= t0 and r.submitted_at < t1)
      select jsonb_build_object(
        'reactivite', (select round(avg(extract(epoch from accepted_at - assigned_at) / 60)::numeric, 1) from a where accepted_at is not null),
        'temps_rapport_visio', (select round(avg(extract(epoch from submitted_at - started_at) / 60)::numeric, 1) from rep where mandate_type = 'visio' and started_at is not null),
        'temps_rapport_rdf', (select round(avg(extract(epoch from submitted_at - started_at) / 60)::numeric, 1) from rep where mandate_type = 'rdf' and started_at is not null),
        'temps_rapport_rdfs', (select round(avg(extract(epoch from submitted_at - started_at) / 60)::numeric, 1) from rep where mandate_type = 'rdfs' and started_at is not null),
        'visio_jour', round((select count(*) from a where mandate_type = 'visio') / v_days, 2),
        'rdf_jour', round((select count(*) from a where mandate_type = 'rdf') / v_days, 2),
        'rdfs_jour', round((select count(*) from a where mandate_type = 'rdfs') / v_days, 2),
        'mots_conclusion', (select round(avg(coalesce(array_length(regexp_split_to_array(trim(rapport_conclusions), '\s+'), 1), 0)), 1) from rep),
        'mots_rapport', (select round(avg(coalesce(array_length(regexp_split_to_array(trim(coalesce(rapport_conclusions,'') || ' ' || coalesce(preconisations_reserves,'') || ' ' || array_to_string(hypotheses, ' ')), '\s+'), 1), 0) + room_words), 1) from rep),
        'pieces_investiguees', (select round(avg(rooms), 1) from rep),
        'photos_rapport', (select round(avg(photos), 1) from rep),
        'videos_rapport', (select round(avg((select count(*) from public.report_media rm
                                              where rm.mandate_id = rep.mandate_id and rm.expert_id = e.id and rm.media_type = 'video')), 1) from rep),
        'redrops', (select count(*) from a where comment = 'transition redrop'),
        'suspensions', (select count(*) from public.mandate_history h join a on a.mandate_id = h.mandate_id
                         where h.status_to = 'suspended' and h.created_at >= t0 and h.created_at < t1),
        'nb_listes_affilie', (select count(*) from public.expert_list_members lm join public.expert_lists l on l.id = lm.list_id and l.organization_id = v_org where lm.expert_id = e.id),
        'nb_zones_affilie', (select count(*) from unnest(regexp_split_to_array(coalesce(e.coverage_zone, ''), '\s*,\s*')) z where z <> ''),
        'note_client_min', e.rating, 'note_client_max', e.rating, 'note_client_moy', e.rating,
        'temps_sur_drop', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from a where drop_at is not null),
        'attrib_visio', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from a where mandate_type = 'visio' and drop_at is not null),
        'attrib_rdf', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from a where mandate_type = 'rdf' and drop_at is not null),
        'attrib_rdfs', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from a where mandate_type = 'rdfs' and drop_at is not null),
        'traitement_visio', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from a where mandate_type = 'visio' and closed_at is not null),
        'traitement_rdf', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from a where mandate_type = 'rdf' and closed_at is not null),
        'traitement_rdfs', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from a where mandate_type = 'rdfs' and closed_at is not null),
        'clotures', (select count(*) from a where closed_at >= t0 and closed_at < t1)
      ) into v;
      v := v || (select jsonb_build_object(
                   'temps_app', q->'temps_app_h', 'amplitude_horaire', q->'amplitude_h', 'disponibilite', q->'disponibilite',
                   'completude', q->'completude', 'fiabilite', q->'fiabilite')
                   from (select public.expert_quality_stats(e.id, t0, t1) q) z)
              || jsonb_build_object(
                   'temps_deplacement', (select round(avg(m.travel_time_min)::numeric, 1) from public.mandates m
                                          where m.travel_expert_id = e.id and m.insurance_org_id = v_org and m.travel_time_min is not null
                                            and exists (select 1 from public.mandate_assignments ma where ma.mandate_id = m.id and ma.expert_id = e.id
                                                          and ma.assigned_at >= t0 and ma.assigned_at < t1)),
                   'respect_creneaux', (select round(100.0 * count(*) filter (where m.arrived_at <= coalesce(m.selected_slot_at, m.slot_1_at) + interval '15 minutes') / nullif(count(*), 0))
                                          from public.mandates m where m.assigned_expert_id = e.id and m.insurance_org_id = v_org and m.arrived_at is not null
                                           and coalesce(m.selected_slot_at, m.slot_1_at) is not null and m.arrived_at >= t0 and m.arrived_at < t1),
                   'retard_arrivee', (select round(avg(extract(epoch from m.arrived_at - coalesce(m.selected_slot_at, m.slot_1_at)) / 60)::numeric, 1)
                                          from public.mandates m where m.assigned_expert_id = e.id and m.insurance_org_id = v_org and m.arrived_at is not null
                                           and coalesce(m.selected_slot_at, m.slot_1_at) is not null and m.arrived_at >= t0 and m.arrived_at < t1));
      v_rows := v_rows || jsonb_build_object('id', e.id, 'label', trim(concat_ws(' ', e.company_name, '—', e.first_name, e.last_name)), 'values', v);
    end loop;
  else
    with m as (select * from public.mandates where insurance_org_id = v_org and created_at >= t0 and created_at < t1)
    select jsonb_build_object(
      'temps_avant_drop', (select round(avg(extract(epoch from drop_at - created_at) / 3600)::numeric, 1) from m where drop_at is not null),
      'temps_sur_drop', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from m where drop_at is not null and assigned_at is not null),
      'attrib_visio', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from m where mandate_type = 'visio' and drop_at is not null and assigned_at is not null),
      'attrib_rdf', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from m where mandate_type = 'rdf' and drop_at is not null and assigned_at is not null),
      'attrib_rdfs', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from m where mandate_type = 'rdfs' and drop_at is not null and assigned_at is not null),
      'traitement_visio', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from m where mandate_type = 'visio' and closed_at is not null and assigned_at is not null),
      'traitement_rdf', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from m where mandate_type = 'rdf' and closed_at is not null and assigned_at is not null),
      'traitement_rdfs', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from m where mandate_type = 'rdfs' and closed_at is not null and assigned_at is not null),
      'demandes_mois', (select concat_ws(' · ', 'visio ' || round(count(*) filter (where mandate_type = 'visio') / v_months, 1),
                                                'RDF ' || round(count(*) filter (where mandate_type = 'rdf') / v_months, 1),
                                                'RDFS ' || round(count(*) filter (where mandate_type = 'rdfs') / v_months, 1)) from m),
      'creation_auto', (select count(*) from m where created_by_user_id is null),
      'creation_manuelle', (select count(*) from m where created_by_user_id is not null),
      'redrops', (select coalesce(sum(redrop_count), 0) from m),
      'suspensions', (select count(*) from public.mandate_history h join public.mandates mm on mm.id = h.mandate_id and mm.insurance_org_id = v_org
                       where h.status_to = 'suspended' and h.created_at >= t0 and h.created_at < t1),
      'clotures', (select concat_ws(' · ', 'visio ' || count(*) filter (where mm.mandate_type = 'visio'), 'RDF ' || count(*) filter (where mm.mandate_type = 'rdf'),
                                    'RDFS ' || count(*) filter (where mm.mandate_type = 'rdfs'))
                     from public.mandates mm where mm.insurance_org_id = v_org and mm.closed_at >= t0 and mm.closed_at < t1),
      'experts_par_zone', (select string_agg(z || ' : ' || n, ' · ' order by n desc, z) from (
                             select z, count(distinct x.id) n from public.experts x,
                                    unnest(regexp_split_to_array(coalesce(x.coverage_zone, ''), '\s*,\s*')) z
                              where z <> '' group by z) s),
      'nb_listes', (select count(*) from public.expert_lists where organization_id = v_org and is_active),
      'temps_suspension', (select round(avg(extract(epoch from fin - debut) / 3600)::numeric, 1) from (
                             select h.created_at debut,
                                    (select min(h2.created_at) from public.mandate_history h2
                                      where h2.mandate_id = h.mandate_id and h2.created_at > h.created_at
                                        and h2.status_to is not null and h2.status_to <> 'suspended') fin
                               from public.mandate_history h join public.mandates mm on mm.id = h.mandate_id and mm.insurance_org_id = v_org
                              where h.status_to = 'suspended' and h.created_at >= t0 and h.created_at < t1) s where fin is not null),
      'temps_reattribution', (select round(avg(extract(epoch from fin - debut) / 3600)::numeric, 1) from (
                             select h.created_at debut,
                                    (select min(h2.created_at) from public.mandate_history h2
                                      where h2.mandate_id = h.mandate_id and h2.created_at > h.created_at and h2.status_to = 'assigned') fin
                               from public.mandate_history h join public.mandates mm on mm.id = h.mandate_id and mm.insurance_org_id = v_org
                              where h.status_from in ('assigned','in_progress','suspended') and h.status_to in ('redrop','dropped','drop_pending')
                                and h.created_at >= t0 and h.created_at < t1) s where fin is not null),
      'recrutements', (select count(*) from public.org_experts oe where oe.organization_id = v_org and oe.source = 'recrutement'
                         and oe.added_at >= t0 and oe.added_at < t1),
      'experts_par_liste', (select round(avg(n), 1) from (select count(lm.expert_id) n from public.expert_lists l
                              left join public.expert_list_members lm on lm.list_id = l.id
                             where l.organization_id = v_org and l.is_active group by l.id) s)
    ) into v;
    v_rows := jsonb_build_array(jsonb_build_object('id', v_org, 'label', (select name from public.organizations where id = v_org), 'values', v));
  end if;

  if coalesce(cardinality(p_kpis), 0) > 0 then
    select coalesce(jsonb_agg(r || jsonb_build_object('values',
             (select coalesce(jsonb_object_agg(k, val), '{}'::jsonb) from jsonb_each(r->'values') x(k, val) where k = any(p_kpis)))), '[]'::jsonb)
      into v_rows from jsonb_array_elements(v_rows) r;
  end if;

  return jsonb_build_object('start', t0::date, 'end', (t1 - interval '1 day')::date, 'scope', coalesce(p_scope, 'experts'), 'rows', v_rows);
end $function$
;

-- ------------------------------------------------------------
-- lock_holder_name
CREATE OR REPLACE FUNCTION public.lock_holder_name(p_user uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select coalesce(nullif(trim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')), ''), 'un autre gestionnaire')
        from public.user_profiles where id = p_user $function$
;

-- ------------------------------------------------------------
-- lock_mandates
CREATE OR REPLACE FUNCTION public.lock_mandates(p_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_blocked jsonb := '[]'::jsonb; v_id uuid; v_l public.mandate_locks%rowtype;
begin
  if not public.is_manager() then return jsonb_build_object('blocked', v_blocked); end if;
  delete from public.mandate_locks where expires_at < now();
  foreach v_id in array coalesce(p_ids, '{}') loop
    select * into v_l from public.mandate_locks where mandate_id = v_id for update;
    if found and v_l.user_id <> auth.uid() then
      v_blocked := v_blocked || jsonb_build_object(
        'mandate_id', v_id,
        'reference', (select reference from public.mandates where id = v_id),
        'holder', public.lock_holder_name(v_l.user_id),
        'until', v_l.expires_at);
    else
      insert into public.mandate_locks (mandate_id, user_id, locked_at, expires_at)
      values (v_id, auth.uid(), now(), now() + interval '10 minutes')
      on conflict (mandate_id) do update set user_id = excluded.user_id, expires_at = excluded.expires_at;
    end if;
  end loop;
  return jsonb_build_object('blocked', v_blocked);
end $function$
;

-- ------------------------------------------------------------
-- log_expert_archive_action
CREATE OR REPLACE FUNCTION public.log_expert_archive_action(p_report_ids uuid[], p_action text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expert uuid := public.current_expert_id(); v_n int;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if p_action not in ('sent','downloaded') then raise exception 'Action inconnue'; end if;
  if coalesce(cardinality(p_report_ids),0) = 0 then raise exception 'Sélectionnez au moins un mandat'; end if;
  if exists (select 1 from unnest(p_report_ids) i
             where not exists (select 1 from public.rdf_reports r join public.mandates m on m.id = r.mandate_id
                               where r.id = i and m.assigned_expert_id = v_expert)) then
    raise exception 'Archive introuvable';
  end if;
  insert into public.activity_logs (user_id, organization_id, entity_type, entity_id, action)
  select auth.uid(), m.insurance_org_id, 'report', r.id, 'archive_' || p_action
    from public.rdf_reports r join public.mandates m on m.id = r.mandate_id where r.id = any(p_report_ids);
  get diagnostics v_n = row_count;
  return v_n;
end $function$
;

-- ------------------------------------------------------------
-- log_expert_archive_filters
CREATE OR REPLACE FUNCTION public.log_expert_archive_filters(p_filters jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if public.current_expert_id() is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'user', auth.uid(), 'archives_searched', coalesce(p_filters, '{}'::jsonb));
end $function$
;

-- ------------------------------------------------------------
-- log_expert_media_event
CREATE OR REPLACE FUNCTION public.log_expert_media_event(p_mandate_id uuid, p_action text, p_seconds integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if public.current_expert_id() is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if p_action not in ('capture_time','capture_back','editor_back') then raise exception 'Action inconnue'; end if;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'mandate', p_mandate_id, p_action, jsonb_build_object('seconds', p_seconds));
end $function$
;

-- ------------------------------------------------------------
-- log_expert_profile_event
CREATE OR REPLACE FUNCTION public.log_expert_profile_event(p_action text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if public.current_expert_id() is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if p_action not in ('stats_report_downloaded') then raise exception 'Action inconnue'; end if;
  insert into public.activity_logs (user_id, entity_type, entity_id, action) values (auth.uid(), 'user', auth.uid(), p_action);
end $function$
;

-- ------------------------------------------------------------
-- log_mandate_assignment_event
CREATE OR REPLACE FUNCTION public.log_mandate_assignment_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- Log quand un mandat est assigné
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.expert_performance_logs (expert_id, event_type, event_data)
    VALUES (
      NEW.expert_id,
      'mandate_assigned',
      jsonb_build_object(
        'mandate_id', NEW.mandate_id,
        'assignment_id', NEW.id,
        'assigned_at', NEW.assigned_at
      )
    );
  END IF;

  -- Log quand un mandat est accepté
  IF TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status = 'accepted' THEN
    INSERT INTO public.expert_performance_logs (expert_id, event_type, event_data)
    VALUES (
      NEW.expert_id,
      'mandate_accepted',
      jsonb_build_object(
        'mandate_id', NEW.mandate_id,
        'assignment_id', NEW.id,
        'accepted_at', NEW.accepted_at,
        'response_time_min', EXTRACT(EPOCH FROM (NEW.accepted_at - NEW.assigned_at)) / 60
      )
    );
  END IF;

  -- Log quand un mandat est refusé
  IF TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status = 'refused' THEN
    INSERT INTO public.expert_performance_logs (expert_id, event_type, event_data)
    VALUES (
      NEW.expert_id,
      'mandate_refused',
      jsonb_build_object(
        'mandate_id', NEW.mandate_id,
        'assignment_id', NEW.id,
        'refused_at', NEW.refused_at
      )
    );
  END IF;

  RETURN NEW;
END;
$function$
;

-- ------------------------------------------------------------
-- log_recruitment_filters
CREATE OR REPLACE FUNCTION public.log_recruitment_filters(p_filters jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  select auth.uid(), 'broadcast', gen_random_uuid(), 'recruitment_filters', p_filters where public.is_manager();
$function$
;

-- ------------------------------------------------------------
-- manager_broadcast
CREATE OR REPLACE FUNCTION public.manager_broadcast(p_type text, p_audience text, p_message text, p_mandate_ids uuid[] DEFAULT '{}'::uuid[], p_unassign boolean DEFAULT false, p_uncloud boolean DEFAULT false, p_expert_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_id uuid := gen_random_uuid(); v_title text;
    v_recipients int := 0; v_unassigned int := 0; v_uncloud int := 0; v_m record;
    v_targeted boolean := cardinality(coalesce(p_expert_ids,'{}')) > 0;
begin
    if auth.uid() is null then raise exception 'Utilisateur non connecté'; end if;
    if not public.is_manager() then raise exception 'Le message groupé est réservé aux gestionnaires'; end if;

    v_title := case p_type when 'alerte' then 'Alerte' when 'anomalie' then 'Anomalie' when 'nouveautes' then 'Nouveautés' end;
    if v_title is null then raise exception 'Type de message invalide : %', p_type; end if;
    if not v_targeted and coalesce(p_audience,'') not in ('connected','all') then raise exception 'Destinataires invalides : %', p_audience; end if;
    if nullif(trim(coalesce(p_message,'')), '') is null then raise exception 'Le message est obligatoire'; end if;
    if (p_unassign or p_uncloud) and cardinality(coalesce(p_mandate_ids,'{}')) = 0 then
        raise exception 'Cochez au moins un mandat pour retirer l''attribution ou sortir du cloud';
    end if;

    -- Destinataires : experts choisis (Liste d'experts) ou connectés / tous (Current_drop)
    insert into public.notifications (user_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
    select e.user_id, 'message', v_title, trim(p_message), 'in_app', false, now(), 'broadcast', v_id, 'dashboard'
      from public.experts e
     where e.user_id is not null
       and (case when v_targeted then e.id = any(p_expert_ids)
                 else (p_audience = 'all' or e.status_experts = 'connecte') end);
    get diagnostics v_recipients = row_count;

    if p_unassign then
        for v_m in select m.id, m.reference, e.user_id as expert_user
                     from public.mandates m left join public.experts e on e.id = m.assigned_expert_id
                    where m.id = any(p_mandate_ids) and m.status in ('assigned','in_progress') loop
            if v_m.expert_user is not null then
                insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
                values (v_m.expert_user, v_m.id, 'status_change', 'Attribution retirée',
                        'Le mandat ' || coalesce(v_m.reference,'') || ' vous a été retiré. ' || trim(p_message),
                        'in_app', false, now(), 'broadcast', v_id, 'mandate');
            end if;
            perform public.transition_mandate_status(v_m.id, 'redrop');
            v_unassigned := v_unassigned + 1;
        end loop;
    end if;

    if p_uncloud then
        for v_m in select m.id from public.mandates m where m.id = any(p_mandate_ids) and m.status in ('dropped','redrop') loop
            perform public.transition_mandate_status(v_m.id, 'drop_pending');
            v_uncloud := v_uncloud + 1;
        end loop;
    end if;

    insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
    values (auth.uid(), 'broadcast', v_id, 'group_message',
            jsonb_build_object('type', p_type, 'audience', case when v_targeted then 'selected' else p_audience end,
                               'message', trim(p_message), 'recipients', v_recipients, 'expert_ids', p_expert_ids,
                               'mandate_ids', p_mandate_ids, 'unassign', p_unassign, 'unassigned', v_unassigned,
                               'uncloud', p_uncloud, 'uncloud_count', v_uncloud));

    return jsonb_build_object('broadcast_id', v_id, 'recipients', v_recipients, 'unassigned', v_unassigned, 'uncloud', v_uncloud);
end;
$function$
;

-- ------------------------------------------------------------
-- mandate_open_duplicate
CREATE OR REPLACE FUNCTION public.mandate_open_duplicate(p_first_name text, p_address text, p_phone text, p_exclude uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if nullif(trim(coalesce(p_first_name, '')), '') is null then return null; end if;
  select jsonb_build_object('id', m.id, 'reference', m.reference, 'status', m.status,
                            'beneficiary', trim(concat_ws(' ', b.first_name, b.last_name)), 'address', m.address_line_1)
    into v
    from public.mandates m join public.beneficiaries b on b.id = m.beneficiary_id
   where m.insurance_org_id = public.current_user_organization_id()
     and m.status not in ('closed', 'cancelled')
     and m.id is distinct from p_exclude
     and lower(trim(b.first_name)) = lower(trim(p_first_name))
     and ((nullif(trim(coalesce(p_address, '')), '') is not null and lower(trim(m.address_line_1)) = lower(trim(p_address)))
          or (length(v_phone) >= 6 and v_phone in (regexp_replace(coalesce(b.mobile_phone, ''), '\D', '', 'g'),
                                                    regexp_replace(coalesce(b.landline_phone, ''), '\D', '', 'g'))))
   order by m.created_at desc limit 1;
  return v;
end $function$
;

-- ------------------------------------------------------------
-- mandate_status_label
CREATE OR REPLACE FUNCTION public.mandate_status_label(s text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case s
    when 'draft' then 'Brouillon' when 'new' then 'Nouveau'
    when 'drop_pending' then 'Liste de drop' when 'dropped' then 'Sur la carte'
    when 'redrop' then 'Redrop' when 'assigned' then 'Attribué'
    when 'in_progress' then 'En cours' when 'waiting_report' then 'En attente de validation'
    when 'suspended' then 'Suspendu' when 'closed' then 'Clôturé'
    when 'cancelled' then 'Annulé' else s end $function$
;

-- ------------------------------------------------------------
-- manual_assign_mandates
CREATE OR REPLACE FUNCTION public.manual_assign_mandates(p_assignments jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := public.current_user_organization_id(); r jsonb; v_ok int := 0; v_err jsonb := '[]'::jsonb;
        v_m uuid; v_e uuid;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if p_assignments is null or jsonb_typeof(p_assignments) <> 'array' or jsonb_array_length(p_assignments) = 0 then
    raise exception 'Aucune attribution à enregistrer';
  end if;
  for r in select * from jsonb_array_elements(p_assignments) loop
    v_m := (r->>'mandate_id')::uuid; v_e := (r->>'expert_id')::uuid;
    begin
      if not exists (select 1 from public.mandates where id = v_m and insurance_org_id = v_org) then
        raise exception 'Mandat introuvable dans votre organisation';
      end if;
      if not exists (select 1 from public.experts e join public.org_experts oe on oe.expert_id = e.id and oe.organization_id = v_org
                      where e.id = v_e and coalesce(e.status_experts::text,'new') <> 'suspendu') then
        raise exception 'Expert absent de votre base ou suspendu';
      end if;
      perform public.transition_mandate_status(v_m, 'assigned', v_e, null, 'manual');
      v_ok := v_ok + 1;
    exception when others then
      v_err := v_err || jsonb_build_object('mandate_id', v_m,
                 'reference', (select reference from public.mandates where id = v_m), 'error', sqlerrm);
    end;
  end loop;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', gen_random_uuid(), 'manual_assignment',
          jsonb_build_object('requested', jsonb_array_length(p_assignments), 'assigned', v_ok, 'errors', v_err));
  return jsonb_build_object('assigned', v_ok, 'errors', v_err);
end $function$
;

-- ------------------------------------------------------------
-- manual_assignment_data
CREATE OR REPLACE FUNCTION public.manual_assignment_data(p_mandate_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := public.current_user_organization_id(); v jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select jsonb_build_object(
    'mandates', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'reference', m.reference, 'mandate_type', m.mandate_type, 'status', m.status,
               'priority', m.priority, 'address', concat_ws(' ', m.address_line_1, m.postal_code, m.city),
               'postal_code', m.postal_code, 'symptom', coalesce(m.symptoms::text, m.description),
               'beneficiary_first_name', b.first_name, 'beneficiary_last_name', b.last_name,
               'beneficiary_email', b.email, 'beneficiary_phone', coalesce(b.mobile_phone, b.landline_phone),
               'locked_by', (select public.lock_holder_name(l.user_id) from public.mandate_locks l
                              where l.mandate_id = m.id and l.user_id <> auth.uid() and l.expires_at > now()))
             order by m.created_at)
        from public.mandates m left join public.beneficiaries b on b.id = m.beneficiary_id
       where m.insurance_org_id = v_org
         and m.status in ('drop_pending','dropped','redrop','suspended')
         and (coalesce(cardinality(p_mandate_ids), 0) = 0 or m.id = any(p_mandate_ids))), '[]'::jsonb),
    'experts', coalesce((
      select jsonb_agg(x order by (x->>'assignments_count')::int desc, x->>'last_name')
        from (select jsonb_build_object(
               'id', e.id, 'company_name', e.company_name, 'siret', e.siret,
               'first_name', e.first_name, 'last_name', e.last_name, 'phone', e.phone, 'email', e.email,
               'address', concat_ws(' ', e.address_line_1, e.postal_code, e.city), 'postal_code', e.postal_code,
               'coverage_zone', e.coverage_zone, 'agreements', to_jsonb(e.agreements), 'rating', e.rating,
               'status', e.status_experts,
               'is_online', coalesce(up.last_seen_at > now() - interval '5 minutes', false),
               'list_ids', coalesce((select jsonb_agg(l.id) from public.expert_list_members lm
                                      join public.expert_lists l on l.id = lm.list_id and l.organization_id = v_org
                                     where lm.expert_id = e.id), '[]'::jsonb),
               'list_names', coalesce((select string_agg(l.name, ', ' order by l.name) from public.expert_list_members lm
                                      join public.expert_lists l on l.id = lm.list_id and l.organization_id = v_org
                                     where lm.expert_id = e.id), ''),
               'assignments_count', (select count(*) from public.mandate_assignments a
                                       join public.mandates m2 on m2.id = a.mandate_id and m2.insurance_org_id = v_org
                                      where a.expert_id = e.id)) x
                from public.experts e
                join public.org_experts oe on oe.expert_id = e.id and oe.organization_id = v_org
                left join public.user_profiles up on up.id = e.user_id
               where coalesce(e.status_experts::text, 'new') <> 'suspendu') s), '[]'::jsonb)
  ) into v;
  return v;
end $function$
;

-- ------------------------------------------------------------
-- mark_my_notifications_read
CREATE OR REPLACE FUNCTION public.mark_my_notifications_read(p_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer;
begin
  update public.notifications set is_read = true, read_at = now()
   where user_id = auth.uid() and coalesce(is_read, false) = false
     and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end $function$
;

-- ------------------------------------------------------------
-- plo_data
CREATE OR REPLACE FUNCTION public.plo_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return jsonb_build_object(
    'strategies', coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('is_template', s.organization_id is null)
                                             order by s.organization_id is not null, s.created_at)
                              from public.plo_strategies s where s.organization_id is null or s.organization_id = v_org), '[]'::jsonb),
    'scores', coalesce((select jsonb_agg(to_jsonb(x)) from public.plo_expert_scores() x), '[]'::jsonb));
end $function$
;

-- ------------------------------------------------------------
-- plo_expert_scores
CREATE OR REPLACE FUNCTION public.plo_expert_scores()
 RETURNS TABLE(expert_id uuid, precision_score integer, reactivite_score integer, rapidite_score integer, avis_client_score integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with base as (
    select e.id, e.rating,
           nullif(k.avg_response_time_min, 0) reac, nullif(k.avg_intervention_duration_min, 0) speed
      from public.experts e left join public.expert_kpis k on k.expert_id = e.id
     where coalesce(e.status_experts::text, 'new') <> 'suspendu'),
  prec as (
    select e.id,
           avg(coalesce(ph.n,0) + coalesce(cardinality(r.inspection_photos),0)) photos,
           avg(coalesce(length(r.rapport_conclusions),0) + coalesce(length(r.inspection_commentaires),0) + coalesce(ph.c,0)) chars
      from public.rdf_reports r join public.experts e on e.user_id = r.created_by
      left join lateral (select sum(coalesce(cardinality(rr.photos),0)) n, sum(coalesce(length(rr.commentaire),0)) c
                           from public.rdf_report_rooms rr where rr.report_id = r.id) ph on true
     where r.status in ('submitted','validated','completed') group by e.id),
  p2 as (select id, (percent_rank() over (order by photos) + percent_rank() over (order by chars)) / 2 v, count(*) over () n from prec),
  r2 as (select id, percent_rank() over (order by reac desc) v, count(*) over () n from base where reac is not null),
  s2 as (select id, percent_rank() over (order by speed desc) v, count(*) over () n from base where speed is not null),
  a2 as (select id, percent_rank() over (order by rating) v, count(*) over () n from base where rating is not null)
  select b.id,
         (select case when n = 1 then 100 else round(v * 100)::int end from p2 where p2.id = b.id),
         (select case when n = 1 then 100 else round(v * 100)::int end from r2 where r2.id = b.id),
         (select case when n = 1 then 100 else round(v * 100)::int end from s2 where s2.id = b.id),
         (select case when n = 1 then 100 else round(v * 100)::int end from a2 where a2.id = b.id)
    from base b
$function$
;

-- ------------------------------------------------------------
-- plo_select
CREATE OR REPLACE FUNCTION public.plo_select(p_precision integer, p_reactivite integer, p_rapidite integer, p_avis_client integer, p_include_no_data boolean DEFAULT false, p_strategy_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ids jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select coalesce(jsonb_agg(expert_id), '[]'::jsonb) into v_ids from public.plo_expert_scores() s
   where (case when s.precision_score   is null then coalesce(p_include_no_data, false) else s.precision_score   >= coalesce(p_precision, 0) end)
     and (case when s.reactivite_score  is null then coalesce(p_include_no_data, false) else s.reactivite_score  >= coalesce(p_reactivite, 0) end)
     and (case when s.rapidite_score    is null then coalesce(p_include_no_data, false) else s.rapidite_score    >= coalesce(p_rapidite, 0) end)
     and (case when s.avis_client_score is null then coalesce(p_include_no_data, false) else s.avis_client_score >= coalesce(p_avis_client, 0) end);
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', coalesce(p_strategy_id, gen_random_uuid()), 'plo_applied',
          jsonb_build_object('strategy_id', p_strategy_id, 'precision', p_precision, 'reactivite', p_reactivite,
                             'rapidite', p_rapidite, 'avis_client', p_avis_client, 'include_no_data', p_include_no_data,
                             'selected', jsonb_array_length(v_ids)));
  return v_ids;
end $function$
;

-- ------------------------------------------------------------
-- purge_user_sessions
CREATE OR REPLACE FUNCTION public.purge_user_sessions()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  delete from public.user_sessions where last_seen_at < now() - interval '31 days';
$function$
;

-- ------------------------------------------------------------
-- recalculate_all_expert_kpis
CREATE OR REPLACE FUNCTION public.recalculate_all_expert_kpis()
 RETURNS TABLE(expert_id uuid, success boolean, error_message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_expert_id uuid;
BEGIN
  FOR v_expert_id IN SELECT id FROM public.experts
  LOOP
    BEGIN
      PERFORM public.recalculate_expert_kpis(v_expert_id);
      
      expert_id := v_expert_id;
      success := true;
      error_message := NULL;
      RETURN NEXT;
      
    EXCEPTION WHEN OTHERS THEN
      expert_id := v_expert_id;
      success := false;
      error_message := SQLERRM;
      RETURN NEXT;
    END;
  END LOOP;
END;
$function$
;

-- ------------------------------------------------------------
-- recalculate_expert_kpis
CREATE OR REPLACE FUNCTION public.recalculate_expert_kpis(p_expert_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_total_mandates integer;
  v_mandates_in_progress integer;
  v_mandates_completed integer;
  v_mandates_refused integer;
  v_redrop_caused integer;
  v_avg_response_time_min numeric;
  v_avg_intervention_duration_min numeric;
  v_avg_rating numeric;
  v_reports_submitted integer;
  v_reports_validated integer;
  v_reports_rejected integer;
  v_report_validation_rate numeric;
  v_mandates_last_30d integer;
  v_reports_last_30d integer;
  v_last_report_at timestamptz;
  v_last_activity_at timestamptz;
begin
  select count(*) into v_total_mandates
  from public.mandate_assignments
  where expert_id = p_expert_id and status in ('accepted', 'pending', 'refused');

  select count(*) into v_mandates_in_progress
  from public.mandate_assignments ma
  join public.mandates m on m.id = ma.mandate_id
  where ma.expert_id = p_expert_id and ma.status = 'accepted'
    and m.status in ('assigned', 'in_progress');

  select count(*) into v_mandates_completed
  from public.mandate_assignments ma
  join public.mandates m on m.id = ma.mandate_id
  where ma.expert_id = p_expert_id and ma.status = 'accepted'
    and m.status in ('closed');

  select count(*) into v_mandates_refused
  from public.mandate_assignments
  where expert_id = p_expert_id and status = 'refused';

  begin
    select coalesce(count(*), 0) into v_redrop_caused
    from public.expert_performance_logs
    where expert_id = p_expert_id and event_type = 'redrop_caused';
  exception when undefined_table then
    v_redrop_caused := 0;
  end;

  if v_redrop_caused = 0 then
    select coalesce(sum(m.redrop_count), 0) into v_redrop_caused
    from public.mandate_assignments ma
    join public.mandates m on m.id = ma.mandate_id
    where ma.expert_id = p_expert_id and ma.status = 'refused';
  end if;

  select coalesce(avg(extract(epoch from (ma.accepted_at - ma.assigned_at)) / 60), 0)
  into v_avg_response_time_min
  from public.mandate_assignments ma
  where ma.expert_id = p_expert_id and ma.status = 'accepted'
    and ma.accepted_at is not null and ma.assigned_at is not null;

  select coalesce(avg(extract(epoch from (i.actual_end_at - i.actual_start_at)) / 60), 0)
  into v_avg_intervention_duration_min
  from public.interventions i
  where i.expert_id = p_expert_id
    and i.actual_start_at is not null and i.actual_end_at is not null;

  if v_avg_intervention_duration_min = 0 then
    select coalesce(avg(extract(epoch from (r.submitted_at - m.started_at)) / 60), 0)
      into v_avg_intervention_duration_min
      from public.rdf_reports r
      join public.experts e on e.user_id = r.created_by
      join public.mandates m on m.id = r.mandate_id
     where e.id = p_expert_id and r.submitted_at is not null and m.started_at is not null
       and r.submitted_at > m.started_at;
  end if;

  select coalesce(rating, 0) into v_avg_rating
  from public.experts where id = p_expert_id;

  -- Rapports d'expertise (rdf_reports, auteur = experts.user_id)
  select
    count(*) filter (where r.status in ('submitted', 'completed', 'validated')),
    count(*) filter (where r.status in ('validated', 'completed') or (r.status = 'submitted' and m.status = 'closed')),
    count(*) filter (where r.rejected_at is not null),
    count(*) filter (where r.created_at >= now() - interval '30 days'),
    max(r.created_at)
  into v_reports_submitted, v_reports_validated, v_reports_rejected,
       v_reports_last_30d, v_last_report_at
  from public.rdf_reports r
  join public.experts e on e.user_id = r.created_by
  join public.mandates m on m.id = r.mandate_id
  where e.id = p_expert_id;

  if v_reports_submitted > 0 then
    v_report_validation_rate := (v_reports_validated::numeric / v_reports_submitted::numeric) * 100;
  else
    v_report_validation_rate := 0;
  end if;

  select count(*) into v_mandates_last_30d
  from public.mandate_assignments
  where expert_id = p_expert_id and assigned_at >= (now() - interval '30 days');

  -- Dernière activité (null si aucune activité)
  v_last_activity_at := nullif(greatest(
    coalesce((select max(assigned_at) from public.mandate_assignments where expert_id = p_expert_id), '-infinity'::timestamptz),
    coalesce(v_last_report_at, '-infinity'::timestamptz),
    coalesce((select max(created_at) from public.interventions where expert_id = p_expert_id), '-infinity'::timestamptz)
  ), '-infinity'::timestamptz);

  insert into public.expert_kpis (
    expert_id, total_mandates, mandates_in_progress, mandates_completed, mandates_refused,
    redrop_caused, avg_response_time_min, avg_intervention_duration_min, avg_rating,
    reports_submitted, reports_validated, reports_rejected, report_validation_rate,
    mandates_last_30d, reports_last_30d, last_activity_at, last_calculated_at, updated_at
  ) values (
    p_expert_id, v_total_mandates, v_mandates_in_progress, v_mandates_completed, v_mandates_refused,
    v_redrop_caused, v_avg_response_time_min, v_avg_intervention_duration_min, v_avg_rating,
    v_reports_submitted, v_reports_validated, v_reports_rejected, v_report_validation_rate,
    v_mandates_last_30d, v_reports_last_30d, v_last_activity_at, now(), now()
  )
  on conflict (expert_id) do update set
    total_mandates = excluded.total_mandates,
    mandates_in_progress = excluded.mandates_in_progress,
    mandates_completed = excluded.mandates_completed,
    mandates_refused = excluded.mandates_refused,
    redrop_caused = excluded.redrop_caused,
    avg_response_time_min = excluded.avg_response_time_min,
    avg_intervention_duration_min = excluded.avg_intervention_duration_min,
    avg_rating = excluded.avg_rating,
    reports_submitted = excluded.reports_submitted,
    reports_validated = excluded.reports_validated,
    reports_rejected = excluded.reports_rejected,
    report_validation_rate = excluded.report_validation_rate,
    mandates_last_30d = excluded.mandates_last_30d,
    reports_last_30d = excluded.reports_last_30d,
    last_activity_at = excluded.last_activity_at,
    last_calculated_at = now(),
    updated_at = now();
end;
$function$
;

-- ------------------------------------------------------------
-- recruit_experts
CREATE OR REPLACE FUNCTION public.recruit_experts(p_expert_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

-- ------------------------------------------------------------
-- recruitment_data
CREATE OR REPLACE FUNCTION public.recruitment_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return jsonb_build_object(
    'last_added_at', (select max(created_at) from public.experts),
    'added_per_month', (select coalesce(jsonb_agg(jsonb_build_object('month', mo, 'count', n) order by mo desc), '[]'::jsonb)
                          from (select date_trunc('month', created_at)::date mo, count(*) n from public.experts group by 1) a),
    'non_collecte', jsonb_build_array('Note assurance', 'Valeur de devis', 'Note PLOMI'),
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
end $function$
;

-- ------------------------------------------------------------
-- recruitment_expert_stats
CREATE OR REPLACE FUNCTION public.recruitment_expert_stats(p_expert_id uuid, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_type text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'completude', (public.expert_quality_stats(p_expert_id, t0, t1))->'completude',
    'fiabilite', (public.expert_quality_stats(p_expert_id, t0, t1))->'fiabilite',
    'fiabilite_detail', (public.expert_quality_stats(p_expert_id, t0, t1))->'fiabilite_detail',
    'disponibilite', (public.expert_quality_stats(p_expert_id, t0, t1))->'disponibilite',
    'contract_type', (select contract_type from public.experts where id = p_expert_id),
    'temps_deplacement_min', (select round(avg(m.travel_time_min)) from public.mandates m
                               where m.travel_expert_id = p_expert_id and m.travel_time_min is not null
                                 and coalesce(m.assigned_at, m.created_at) >= t0 and coalesce(m.assigned_at, m.created_at) < t1),
    'respect_creneaux', (select round(100.0 * count(*) filter (where m.arrived_at <= coalesce(m.selected_slot_at, m.slot_1_at) + interval '15 minutes') / nullif(count(*), 0))
                           from public.mandates m where m.assigned_expert_id = p_expert_id and m.arrived_at is not null
                            and coalesce(m.selected_slot_at, m.slot_1_at) is not null and m.arrived_at >= t0 and m.arrived_at < t1),
    'ecart_arrivee_min', (select round(avg(extract(epoch from m.arrived_at - coalesce(m.selected_slot_at, m.slot_1_at)) / 60)::numeric)
                           from public.mandates m where m.assigned_expert_id = p_expert_id and m.arrived_at is not null
                            and coalesce(m.selected_slot_at, m.slot_1_at) is not null and m.arrived_at >= t0 and m.arrived_at < t1),
    'non_collecte', jsonb_build_array(
                                      'Note assurance moyenne', 'Valeur moyenne de devis', 'Note PLOMI'))
  into v;
  if p_start is not null or p_end is not null or p_type is not null then
    insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
    values (auth.uid(), 'broadcast', p_expert_id, 'recruitment_stats_viewed',
            jsonb_build_object('start', p_start, 'end', p_end, 'type', p_type));
  end if;
  return v;
end $function$
;

-- ------------------------------------------------------------
-- recruitment_fiche
CREATE OR REPLACE FUNCTION public.recruitment_fiche(p_expert_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  values (auth.uid(), 'broadcast', p_expert_id, 'recruitment_fiche_viewed', jsonb_build_object('locked_by', v_holder));
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
end $function$
;

-- ------------------------------------------------------------
-- refresh_auto_expert_lists
CREATE OR REPLACE FUNCTION public.refresh_auto_expert_lists()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l record; v_changes integer := 0; n integer;
begin
  for l in select id, auto_rule, organization_id from public.expert_lists where auto_rule is not null and is_active loop
    delete from public.expert_list_members m
     where m.list_id = l.id
       and (m.expert_id not in (select public.expert_list_rule_members(l.auto_rule))
            or not exists (select 1 from public.org_experts oe where oe.expert_id = m.expert_id and oe.organization_id = l.organization_id));
    get diagnostics n = row_count; v_changes := v_changes + n;
    insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
    select l.id, x, null from public.expert_list_rule_members(l.auto_rule) x
     where exists (select 1 from public.org_experts oe where oe.expert_id = x and oe.organization_id = l.organization_id)
    on conflict (list_id, expert_id) do nothing;
    get diagnostics n = row_count; v_changes := v_changes + n;
  end loop;
  return v_changes;
end $function$
;

-- ------------------------------------------------------------
-- release_mandates
CREATE OR REPLACE FUNCTION public.release_mandates(p_ids uuid[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ delete from public.mandate_locks where mandate_id = any(coalesce(p_ids,'{}')) and user_id = auth.uid() $function$
;

-- ------------------------------------------------------------
-- report_is_complete
CREATE OR REPLACE FUNCTION public.report_is_complete(p_report_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select nullif(trim(coalesce(r.rapport_conclusions,'')),'') is not null
     and nullif(trim(coalesce(r.preconisations_reserves,'')),'') is not null
     and coalesce(cardinality(r.hypotheses),0) > 0
     and (m.mandate_type::text = 'visio' or (
          exists (select 1 from public.rdf_report_rooms rr where rr.report_id = r.id)
          and not exists (
            select 1 from public.rdf_report_rooms rr where rr.report_id = r.id and (
              nullif(trim(coalesce(rr.room,'')),'') is null
              or nullif(trim(coalesce(rr.commentaire,'')),'') is null
              or coalesce(cardinality(rr.photos),0) = 0
              or (rr.step in (1,2) and rr.infiltration is null)
              or (rr.step = 3 and rr.gaz_detecte is null)
              or (rr.step = 4 and (nullif(trim(coalesce(rr.wall,'')),'') is null or nullif(trim(coalesce(rr.matiere,'')),'') is null
                                   or rr.sonde_type is null or rr.sonde_percent is null))))))
    from public.rdf_reports r join public.mandates m on m.id = r.mandate_id
   where r.id = p_report_id;
$function$
;

-- ------------------------------------------------------------
-- resolve_beneficiary
CREATE OR REPLACE FUNCTION public.resolve_beneficiary(p_b jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := public.current_user_organization_id(); v_id uuid;
        v_fn text := nullif(trim(coalesce(p_b->>'first_name', '')), '');
        v_ln text := nullif(trim(coalesce(p_b->>'last_name', '')), '');
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if v_fn is null or v_ln is null then raise exception 'Le nom et le prénom du bénéficiaire sont obligatoires'; end if;
  select id into v_id from public.beneficiaries
   where organization_id = v_org and lower(first_name) = lower(v_fn) and lower(last_name) = lower(v_ln)
   order by created_at desc limit 1;
  if v_id is null then
    insert into public.beneficiaries (organization_id, first_name, last_name, mobile_phone, landline_phone, email)
    values (v_org, v_fn, v_ln, nullif(trim(coalesce(p_b->>'mobile_phone', '')), ''),
            nullif(trim(coalesce(p_b->>'landline_phone', '')), ''), nullif(lower(trim(coalesce(p_b->>'email', ''))), ''))
    returning id into v_id;
  else
    update public.beneficiaries
       set mobile_phone = coalesce(nullif(trim(coalesce(p_b->>'mobile_phone', '')), ''), mobile_phone),
           landline_phone = coalesce(nullif(trim(coalesce(p_b->>'landline_phone', '')), ''), landline_phone),
           email = coalesce(nullif(lower(trim(coalesce(p_b->>'email', ''))), ''), email),
           updated_at = now()
     where id = v_id;
  end if;
  return v_id;
end $function$
;

-- ------------------------------------------------------------
-- rls_auto_enable
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$
;

-- ------------------------------------------------------------
-- save_expert_list
CREATE OR REPLACE FUNCTION public.save_expert_list(p_list_id uuid, p_name text, p_expert_ids uuid[], p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := public.current_user_organization_id(); v_id uuid := p_list_id; v_name text := nullif(trim(coalesce(p_name,'')), '');
        v_ids uuid[]; v_warn jsonb := '[]'::jsonb; v_dup text; v_new boolean := p_list_id is null;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if v_name is null then raise exception 'Nommez votre liste'; end if;
  select coalesce(array_agg(distinct x), '{}') into v_ids
    from unnest(coalesce(p_expert_ids, '{}')) x
   where exists (select 1 from public.org_experts oe where oe.expert_id = x and oe.organization_id = v_org);
  if cardinality(v_ids) = 0 then raise exception 'Ajoutez au moins un expert de votre base à la liste'; end if;
  if not v_new then
    if not exists (select 1 from public.expert_lists where id = v_id and organization_id = v_org) then
      raise exception 'Liste introuvable dans votre organisation';
    end if;
    if exists (select 1 from public.expert_lists where id = v_id and auto_rule is not null) then
      raise exception 'Les listes automatiques (KPI, agréments) se remplissent seules et ne peuvent pas être modifiées à la main';
    end if;
  end if;
  if not coalesce(p_force, false) then
    select string_agg(l.name, ', ') into v_dup from public.expert_lists l
     where l.organization_id = v_org and l.is_active and lower(trim(l.name)) = lower(v_name)
       and l.id is distinct from v_id;
    if v_dup is not null then v_warn := v_warn || to_jsonb('Une liste porte déjà ce nom : ' || v_dup); end if;
    select string_agg(l.name, ', ') into v_dup from public.expert_lists l
     where l.organization_id = v_org and l.is_active and l.id is distinct from v_id
       and (select coalesce(array_agg(m.expert_id order by m.expert_id), '{}') from public.expert_list_members m where m.list_id = l.id)
           = (select array_agg(x order by x) from unnest(v_ids) x);
    if v_dup is not null then v_warn := v_warn || to_jsonb('Mêmes membres que : ' || v_dup); end if;
    if jsonb_array_length(v_warn) > 0 then
      return jsonb_build_object('status', 'warning', 'warnings', v_warn);
    end if;
  end if;
  if v_new then
    insert into public.expert_lists (organization_id, name, is_active, created_by_user_id)
    values (v_org, v_name, true, auth.uid()) returning id into v_id;
  else
    update public.expert_lists set name = v_name, updated_at = now() where id = v_id;
  end if;
  delete from public.expert_list_members where list_id = v_id and expert_id <> all(v_ids);
  insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
  select v_id, x, auth.uid() from unnest(v_ids) x
  on conflict (list_id, expert_id) do nothing;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', v_id, case when v_new then 'expert_list_created' else 'expert_list_updated' end,
          jsonb_build_object('list_id', v_id, 'name', v_name, 'members', cardinality(v_ids), 'forced', coalesce(p_force,false)));
  return jsonb_build_object('status', 'saved', 'id', v_id, 'members', cardinality(v_ids));
end $function$
;

-- ------------------------------------------------------------
-- save_mandate_form
CREATE OR REPLACE FUNCTION public.save_mandate_form(p_mandate_id uuid, p_data jsonb, p_drop boolean DEFAULT false, p_list_ids uuid[] DEFAULT NULL::uuid[], p_pending boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public.current_user_organization_id();
  v_id uuid := p_mandate_id;
  v_data jsonb;
  v_cols text;
  v_status text;
  v_editable text[] := array[
    'beneficiary_id','mandate_type','priority','address_line_1','address_line_2','postal_code','city',
    'comments','description','sinister_type','defect_type','affected_rooms','covering_type','appliance_type',
    'installation_type','prerequisites','scheduled_date','slot_1_at','slot_2_at','slot_3_at',
    'secondary_contact_first_name','secondary_contact_last_name','secondary_contact_mobile','secondary_contact_phone',
    'location_type','residence_type','floor','entry_code','sms_alert_enabled','email_alert_enabled','network_available','symptoms','affected_surfaces'];
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_data
    from jsonb_each(coalesce(p_data, '{}'::jsonb))
   where key = any(v_editable) and value not in ('null'::jsonb, '""'::jsonb);

  if v_data->>'beneficiary_id' is null and jsonb_typeof(p_data->'beneficiary') = 'object' then
    v_data := v_data || jsonb_build_object('beneficiary_id', public.resolve_beneficiary(p_data->'beneficiary'));
  end if;

  if v_id is null then
    if v_data->>'mandate_type' is null then raise exception 'Le type de mandat est obligatoire'; end if;
    if v_data->>'address_line_1' is null then raise exception 'L''adresse est obligatoire'; end if;
    if v_data->>'beneficiary_id' is null then raise exception 'Le bénéficiaire est obligatoire'; end if;
    select string_agg(quote_ident(k), ', ') into v_cols from jsonb_object_keys(v_data) k;
    execute format(
      'insert into public.mandates (%1$s, insurance_org_id, created_by_user_id, status)
       select %1$s, $2, auth.uid(), ''draft'' from jsonb_populate_record(null::public.mandates, $1)
       returning id', v_cols)
      into v_id using v_data, v_org;
  else
    if not exists (select 1 from public.mandates where id = v_id and insurance_org_id = v_org) then
      raise exception 'Mandat introuvable dans votre organisation';
    end if;
    if not exists (select 1 from public.mandates where id = v_id and status in ('draft','new','drop_pending')) then
      raise exception 'Ce mandat n''est plus modifiable depuis ce formulaire';
    end if;
    if v_data <> '{}'::jsonb then
      select string_agg(quote_ident(k), ', ') into v_cols from jsonb_object_keys(v_data) k;
      execute format(
        'update public.mandates m set (%1$s) = (select %1$s from jsonb_populate_record(m, $1)) where m.id = $2', v_cols)
        using v_data, v_id;
    end if;
  end if;

  if cardinality(coalesce(p_list_ids, '{}')) > 0 then
    if exists (select 1 from unnest(p_list_ids) x
                where not exists (select 1 from public.expert_lists l where l.id = x and l.organization_id = v_org and l.is_active)) then
      raise exception 'Liste introuvable dans votre organisation';
    end if;
    perform public.drop_mandate(v_id, p_list_ids);
  elsif coalesce(p_drop, false) then
    perform public.drop_mandate(v_id);
  elsif coalesce(p_pending, false) then
    select status into v_status from public.mandates where id = v_id;
    if v_status in ('draft', 'new') then perform public.transition_mandate_status(v_id, 'drop_pending'); end if;
  end if;
  return v_id;
end $function$
;

-- ------------------------------------------------------------
-- save_plo_strategy
CREATE OR REPLACE FUNCTION public.save_plo_strategy(p_id uuid, p_name text, p_precision integer, p_reactivite integer, p_rapidite integer, p_avis_client integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid := public.current_user_organization_id(); v_id uuid := p_id; v_name text := nullif(trim(coalesce(p_name,'')), '');
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if v_name is null then raise exception 'Nommez la stratégie'; end if;
  if least(p_precision, p_reactivite, p_rapidite, p_avis_client) < 0 or greatest(p_precision, p_reactivite, p_rapidite, p_avis_client) > 100 then
    raise exception 'Les seuils vont de 0 à 100 %%';
  end if;
  if v_id is null then
    insert into public.plo_strategies (organization_id, name, precision_min, reactivite_min, rapidite_min, avis_client_min, created_by_user_id)
    values (v_org, v_name, p_precision, p_reactivite, p_rapidite, p_avis_client, auth.uid()) returning id into v_id;
  else
    if not exists (select 1 from public.plo_strategies where id = v_id and organization_id = v_org) then
      raise exception 'Les modèles du cahier des charges ne se modifient pas : créez une nouvelle stratégie';
    end if;
    update public.plo_strategies set name = v_name, precision_min = p_precision, reactivite_min = p_reactivite,
           rapidite_min = p_rapidite, avis_client_min = p_avis_client, updated_at = now() where id = v_id;
  end if;
  return v_id;
end $function$
;

-- ------------------------------------------------------------
-- set_updated_at
CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
    new.updated_at = now();
    return new;
end;
$function$
;

-- ------------------------------------------------------------
-- sync_mandate_visibility
CREATE OR REPLACE FUNCTION public.sync_mandate_visibility()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
    if new.status in ('dropped','redrop') then
        new.visible_on_map := true;
        if new.drop_at is null then
            new.drop_at := now();
        end if;
    else
        new.visible_on_map := false;
    end if;
    return new;
end;
$function$
;

-- ------------------------------------------------------------
-- sync_user_email
CREATE OR REPLACE FUNCTION public.sync_user_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.email is distinct from old.email then
    update public.user_profiles set email = new.email, updated_at = now() where id = new.id;
    update public.experts set email = new.email, updated_at = now() where user_id = new.id;
  end if;
  return new;
end $function$
;

-- ------------------------------------------------------------
-- toggle_kpi_favorite
CREATE OR REPLACE FUNCTION public.toggle_kpi_favorite(p_code text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if exists (select 1 from public.kpi_favorites where user_id = auth.uid() and kpi_code = p_code) then
    delete from public.kpi_favorites where user_id = auth.uid() and kpi_code = p_code;
    return false;
  end if;
  insert into public.kpi_favorites (user_id, kpi_code) values (auth.uid(), p_code);
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', gen_random_uuid(), 'kpi_favorite_added', jsonb_build_object('kpi', p_code));
  return true;
end $function$
;

-- ------------------------------------------------------------
-- touch_presence
CREATE OR REPLACE FUNCTION public.touch_presence()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if auth.uid() is null then return; end if;
  update public.user_profiles set last_seen_at = now(), presence_status = 'online' where id = auth.uid();
  select id into v_id from public.user_sessions
   where user_id = auth.uid() and last_seen_at > now() - interval '5 minutes'
   order by last_seen_at desc limit 1;
  if v_id is null then
    insert into public.user_sessions (user_id) values (auth.uid());
  else
    update public.user_sessions set last_seen_at = now() where id = v_id;
  end if;
  delete from public.user_sessions where user_id = auth.uid() and last_seen_at < now() - interval '31 days';
end $function$
;

-- ------------------------------------------------------------
-- transition_mandate_status
CREATE OR REPLACE FUNCTION public.transition_mandate_status(p_mandate_id uuid, p_new_status mandate_status, p_expert_id uuid DEFAULT NULL::uuid, p_motif text DEFAULT NULL::text, p_assignment_type assignment_type DEFAULT 'manual'::assignment_type, p_list_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_current  mandate_status;
    v_expert   uuid;
    v_allowed  mandate_status[];
begin
    select status, assigned_expert_id into v_current, v_expert
    from public.mandates where id = p_mandate_id for update;
    if not found then
        raise exception 'Mandat introuvable : %', p_mandate_id;
    end if;

    -- Un mandat déjà diffusé une fois (drop_at renseigné) revient sur la carte en redrop
    if p_new_status = 'dropped' and v_current = 'drop_pending'
       and exists (select 1 from public.mandates where id = p_mandate_id and drop_at is not null) then
        p_new_status := 'redrop';
    end if;

    -- Verrou gestionnaire (F17) : l'expert attribué / qui prend le mandat n'est jamais bloqué
    if public.is_manager()
       and not (public.current_expert_id() is not null
                and public.current_expert_id() in (coalesce(v_expert, '00000000-0000-0000-0000-000000000000'::uuid),
                                                  coalesce(p_expert_id, '00000000-0000-0000-0000-000000000000'::uuid))) then
        if exists (select 1 from public.mandate_locks
                    where mandate_id = p_mandate_id and user_id <> auth.uid() and expires_at > now()) then
            raise exception 'Mandat % en cours de traitement par %',
                (select reference from public.mandates where id = p_mandate_id),
                (select public.lock_holder_name(user_id) from public.mandate_locks where mandate_id = p_mandate_id);
        end if;
        insert into public.mandate_locks (mandate_id, user_id, locked_at, expires_at)
        values (p_mandate_id, auth.uid(), now(), now() + interval '10 minutes')
        on conflict (mandate_id) do update set user_id = excluded.user_id, expires_at = excluded.expires_at;
    end if;

    v_allowed := case v_current
        when 'draft'          then array['drop_pending','cancelled']::mandate_status[]
        when 'new'            then array['drop_pending','cancelled']::mandate_status[]
        when 'drop_pending'   then array['dropped','redrop','assigned','cancelled']::mandate_status[]
        when 'dropped'        then array['assigned','drop_pending','cancelled']::mandate_status[]
        when 'redrop'         then array['assigned','drop_pending','cancelled']::mandate_status[]
        when 'assigned'       then array['in_progress','drop_pending','redrop','suspended','cancelled']::mandate_status[]
        when 'in_progress'    then array['waiting_report','redrop','suspended']::mandate_status[]
        when 'waiting_report' then array['closed','redrop','assigned']::mandate_status[]
        when 'suspended'      then array['redrop','assigned','cancelled']::mandate_status[]
        else                       array[]::mandate_status[]
    end;

    if not (p_new_status = any(v_allowed)) then
        raise exception 'Transition interdite : % → % (autorisées : %)', v_current, p_new_status, v_allowed;
    end if;

    if p_new_status = 'assigned' and p_expert_id is null then
        raise exception 'Un expert est requis pour passer en assigned';
    end if;

    if p_list_ids is not null and cardinality(p_list_ids) > 0
       and p_new_status not in ('dropped','redrop') then
        raise exception 'Les listes ne s''utilisent qu''avec un drop ou un redrop';
    end if;

    update public.mandates set
        status = p_new_status,
        priority = case when p_new_status = 'redrop' then 'critical'::priority_level else priority end,
        dropped_by = case when p_new_status in ('dropped','redrop') then coalesce(auth.uid(), dropped_by) else dropped_by end,
        started_at = case
            when p_new_status = 'in_progress' then now()
            when p_new_status in ('drop_pending','redrop','assigned') then null
            else started_at end,
        assigned_expert_id = case
            when p_new_status = 'assigned' then p_expert_id
            when p_new_status in ('drop_pending','redrop') then null
            else assigned_expert_id end,
        assigned_at = case
            when p_new_status = 'assigned' then now()
            when p_new_status in ('drop_pending','redrop') then null
            else assigned_at end,
        selected_slot_at = case when p_new_status in ('drop_pending','redrop','assigned') then null else selected_slot_at end,
        closed_at = case when p_new_status = 'closed' then now() else closed_at end,
        motif_abandon = coalesce(nullif(p_motif, ''), motif_abandon),
        date_abandon  = case when nullif(p_motif, '') is not null then now() else date_abandon end,
        target_list_ids = case
            when p_new_status in ('dropped','redrop') then coalesce(p_list_ids, '{}')
            when p_new_status in ('drop_pending','cancelled') then '{}'
            else target_list_ids end
    where id = p_mandate_id;

    if p_new_status in ('drop_pending','redrop','cancelled','assigned') then
        update public.mandate_assignments
           set status = 'cancelled', cancelled_at = now(),
               comment = coalesce(comment, 'transition ' || p_new_status)
         where mandate_id = p_mandate_id and status in ('pending','accepted');
    end if;

    if p_new_status = 'assigned' then
        insert into public.mandate_assignments
            (mandate_id, expert_id, assignment_type, assigned_by_user_id, status, assigned_at, accepted_at)
        values
            (p_mandate_id, p_expert_id, p_assignment_type, auth.uid(),
             case when p_assignment_type = 'manual' then 'pending'::assignment_status else 'accepted'::assignment_status end,
             now(),
             case when p_assignment_type = 'manual' then null else now() end);
    end if;

    if p_new_status = 'in_progress' then
        update public.mandate_assignments
           set status = 'accepted', accepted_at = now()
         where mandate_id = p_mandate_id and expert_id = v_expert and status = 'pending';
    end if;

    insert into public.activity_logs (entity_type, entity_id, action, old_values_json, new_values_json)
    values ('mandate', p_mandate_id, 'status_transition',
            jsonb_build_object('status', v_current),
            jsonb_build_object('status', p_new_status, 'by', auth.uid(),
                               'expert_id', p_expert_id, 'motif', p_motif,
                               'assignment_type', case when p_new_status = 'assigned' then p_assignment_type end,
                               'list_ids', p_list_ids));
end;
$function$
;

-- ------------------------------------------------------------
-- travel_pending
CREATE OR REPLACE FUNCTION public.travel_pending(p_token text, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  return jsonb_build_object(
    'key', (select decrypted_secret from vault.decrypted_secrets where name = 'google_maps_key'),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'from', x.latitude || ',' || x.longitude, 'to', m.latitude || ',' || m.longitude, 'expert_id', x.id))
      from (select m.* from public.mandates m
             where m.assigned_expert_id is not null and m.latitude is not null and m.longitude is not null
               and (m.travel_expert_id is distinct from m.assigned_expert_id)
             order by m.assigned_at desc nulls last limit p_limit) m
      join public.experts x on x.id = m.assigned_expert_id and x.latitude is not null and x.longitude is not null), '[]'::jsonb));
end $function$
;

-- ------------------------------------------------------------
-- travel_save
CREATE OR REPLACE FUNCTION public.travel_save(p_token text, p_mandate_id uuid, p_expert_id uuid, p_minutes integer, p_km numeric, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  update public.mandates set travel_time_min = p_minutes, travel_distance_km = p_km, travel_expert_id = p_expert_id,
         travel_computed_at = now(), travel_error = p_error
   where id = p_mandate_id;
end $function$
;

-- ------------------------------------------------------------
-- trg_kpi_on_assignment
CREATE OR REPLACE FUNCTION public.trg_kpi_on_assignment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_event kpi_event_type;
  v_mandate public.mandates%rowtype;
begin
  -- Détecter le type d'événement
  if new.status = 'accepted' and (old.status is null or old.status != 'accepted') then
    v_event := 'mandate_accepted';

  elsif new.status in ('refused', 'expired') and old.status = 'pending' then
    v_event := case new.status
      when 'refused'  then 'mandate_refused'
      when 'expired'  then 'mandate_expired'
    end;

    -- Logger aussi le redrop causé
    insert into public.expert_performance_logs
      (expert_id, mandate_id, event_type, metadata)
    values
      (new.expert_id, new.mandate_id, 'redrop_caused',
       jsonb_build_object('reason', new.status, 'comment', new.comment));
  else
    return new;
  end if;

  -- Logger l'événement principal
  insert into public.expert_performance_logs
    (expert_id, mandate_id, event_type, metadata)
  values
    (new.expert_id, new.mandate_id, v_event,
     jsonb_build_object('assignment_id', new.id));

  -- Recalculer les KPIs
  perform public.recalculate_expert_kpis(new.expert_id);

  return new;
end;
$function$
;

-- ------------------------------------------------------------
-- trg_kpi_on_intervention
CREATE OR REPLACE FUNCTION public.trg_kpi_on_intervention()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_duration_min numeric;
begin
  if new.status = 'in_progress' and old.status = 'scheduled' then

    insert into public.expert_performance_logs
      (expert_id, mandate_id, event_type)
    values (new.expert_id, new.mandate_id, 'intervention_started');

  elsif new.status = 'completed' and old.status = 'in_progress' then

    -- Calculer la durée
    if new.actual_start_at is not null and new.actual_end_at is not null then
      v_duration_min := extract(epoch from (new.actual_end_at - new.actual_start_at)) / 60;
    end if;

    insert into public.expert_performance_logs
      (expert_id, mandate_id, event_type, value_num,
       metadata)
    values (
      new.expert_id, new.mandate_id, 'intervention_completed',
      v_duration_min,
      jsonb_build_object(
        'duration_min', v_duration_min,
        'customer_feedback', new.customer_feedback
      )
    );

    perform public.recalculate_expert_kpis(new.expert_id);
  end if;

  return new;
end;
$function$
;

-- ------------------------------------------------------------
-- trg_kpi_on_mandate_closed
CREATE OR REPLACE FUNCTION public.trg_kpi_on_mandate_closed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_expert uuid;
begin
  for v_expert in
    select distinct e.id
    from public.rdf_reports r
    join public.experts e on e.user_id = r.created_by
    where r.mandate_id = new.id
  loop
    if new.status = 'closed' then
      insert into public.expert_performance_logs (expert_id, mandate_id, event_type, metadata)
      values (v_expert, new.id, 'report_validated',
              jsonb_build_object('validated_by', auth.uid()));
    end if;
    perform public.recalculate_expert_kpis(v_expert);
  end loop;
  return new;
end;
$function$
;

-- ------------------------------------------------------------
-- trg_kpi_on_rdf_report
CREATE OR REPLACE FUNCTION public.trg_kpi_on_rdf_report()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_expert uuid;
  v_log boolean := false;
begin
  select id into v_expert from public.experts where user_id = new.created_by;
  if v_expert is null then
    return new;
  end if;

  if new.status in ('submitted', 'completed') then
    if tg_op = 'INSERT' then
      v_log := true;
    elsif old.status = 'draft' then
      v_log := true;
    end if;
  end if;

  if v_log then
    insert into public.expert_performance_logs (expert_id, mandate_id, event_type, metadata)
    values (v_expert, new.mandate_id, 'report_submitted',
            jsonb_build_object('report_id', new.id, 'report_type', 'rdf'));
  end if;

  perform public.recalculate_expert_kpis(v_expert);
  return new;
end;
$function$
;

-- ------------------------------------------------------------
-- trg_notifications_normaliser
CREATE OR REPLACE FUNCTION public.trg_notifications_normaliser()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.mandate_id is null and new.entity_type::text = 'mandate' and new.entity_id is not null then
    new.mandate_id := new.entity_id;
  end if;
  if new.mandate_id is null and new.entity_type::text = 'report' and new.entity_id is not null then
    select mandate_id into new.mandate_id from public.rdf_reports where id = new.entity_id;
  end if;
  if new.mandate_id is not null and new.entity_id is null then
    new.entity_id := new.mandate_id;
    new.entity_type := coalesce(new.entity_type, 'mandate');
    new.target_type := coalesce(new.target_type, 'mandate_details');
  end if;
  return new;
end $function$
;

-- ------------------------------------------------------------
-- trg_org_experts_refresh
CREATE OR REPLACE FUNCTION public.trg_org_experts_refresh()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ begin perform public.refresh_auto_expert_lists(); return null; end $function$
;

-- ------------------------------------------------------------
-- trg_refresh_auto_expert_lists
CREATE OR REPLACE FUNCTION public.trg_refresh_auto_expert_lists()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ begin perform public.refresh_auto_expert_lists(); return null; end $function$
;

-- ------------------------------------------------------------
-- trg_validate_report_on_close
CREATE OR REPLACE FUNCTION public.trg_validate_report_on_close()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.rdf_reports
     set status = 'validated', validated_at = now(), validated_by_user_id = auth.uid()
   where mandate_id = new.id and status = 'submitted';
  return new;
end $function$
;

-- ------------------------------------------------------------
-- unlock_expert_fiche
CREATE OR REPLACE FUNCTION public.unlock_expert_fiche(p_expert_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ delete from public.expert_fiche_locks where expert_id = p_expert_id
        and organization_id = public.current_user_organization_id() and user_id = auth.uid() $function$
;

-- ------------------------------------------------------------
-- update_expert_names
CREATE OR REPLACE FUNCTION public.update_expert_names()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  -- Mettre à jour les colonnes avec les données de l'expert
  SELECT first_name, last_name INTO NEW.expert_first_name, NEW.expert_last_name
  FROM public.experts
  WHERE id = NEW.assigned_expert_id;
  
  RETURN NEW;
END;
$function$
;

-- ------------------------------------------------------------
-- update_investigation_report_status_dates
CREATE OR REPLACE FUNCTION public.update_investigation_report_status_dates()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.status = 'transmis' AND (OLD.status IS NULL OR OLD.status != 'transmis') THEN
    NEW.transmitted_at = now();
  END IF;
  
  IF NEW.status = 'accepter' AND (OLD.status IS NULL OR OLD.status != 'accepter') THEN
    NEW.accepted_at = now();
  END IF;
  
  IF NEW.status = 'refuser' AND (OLD.status IS NULL OR OLD.status != 'refuser') THEN
    NEW.refused_at = now();
  END IF;
  
  RETURN NEW;
END;
$function$
;

-- ------------------------------------------------------------
-- update_investigation_reports_updated_at
CREATE OR REPLACE FUNCTION public.update_investigation_reports_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$
;

-- ------------------------------------------------------------
-- update_updated_at_column
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$
;
COMMENT ON FUNCTION update_updated_at_column() IS 'Fonction trigger pour mettre à jour automatiquement la colonne updated_at';

-- ------------------------------------------------------------
-- update_workflow_stage
CREATE OR REPLACE FUNCTION public.update_workflow_stage()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.workflow_stage := CASE
    WHEN NEW.status IN ('new', 'draft', 'drop_pending') THEN 'pending'::workflow_stage
    WHEN NEW.status IN ('dropped', 'assigned', 'in_progress', 'waiting_report', 'suspended', 'planning', 'redrop') THEN 'active'::workflow_stage
    WHEN NEW.status IN ('closed', 'cancelled') THEN 'archived'::workflow_stage
    ELSE 'pending'::workflow_stage
  END;
  RETURN NEW;
END;
$function$
;
