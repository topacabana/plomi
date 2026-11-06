-- CC C / D : archives de l'expert (1 an), détail + KPIs du rapport, traçabilité
create or replace function public.expert_archives()
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
end $$;

create or replace function public.log_expert_archive_filters(p_filters jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_expert_id() is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'user', auth.uid(), 'archives_searched', coalesce(p_filters, '{}'::jsonb));
end $$;

create or replace function public.expert_archive_detail(p_mandate_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
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
end $$;

create or replace function public.log_expert_archive_action(p_report_ids uuid[], p_action text)
returns int language plpgsql security definer set search_path = public as $$
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
end $$;

revoke all on function public.expert_archives(), public.log_expert_archive_filters(jsonb),
  public.expert_archive_detail(uuid), public.log_expert_archive_action(uuid[], text) from public, anon;
grant execute on function public.expert_archives(), public.log_expert_archive_filters(jsonb),
  public.expert_archive_detail(uuid), public.log_expert_archive_action(uuid[], text) to authenticated;
