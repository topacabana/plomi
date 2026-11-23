-- Modification d'un mandat tout au long de sa vie, jusqu'à l'archivage (décision du 23/11/2026).
-- * save_mandate_form accepte la mise à jour de tout mandat non archivé (≠ closed / cancelled).
--   Après la liste de drop : pas de changement de statut depuis ce formulaire (ni drop, ni liste de drop) ;
--   type de mandat figé ; créneaux figés dès qu'un expert est attribué.
-- * Chaque modification est tracée dans activity_logs (action « mandate_updated » → « Mandat modifié » dans
--   l'historique), avec les anciennes et nouvelles valeurs des seuls champs modifiés.
-- * manager_mandate_prefill lit le mandat quel que soit son statut non archivé (plus seulement les brouillons).
create or replace function public.save_mandate_form(p_mandate_id uuid, p_data jsonb, p_drop boolean DEFAULT false, p_list_ids uuid[] DEFAULT NULL::uuid[], p_pending boolean DEFAULT false)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_user_organization_id();
  v_id uuid := p_mandate_id;
  v_data jsonb;
  v_cols text;
  v_status text;
  v_old jsonb;
  v_new jsonb;
  v_old_ch jsonb := '{}'::jsonb;
  v_new_ch jsonb := '{}'::jsonb;
  v_labels text[] := '{}';
  v_ben_old jsonb;
  v_ben_new jsonb;
  k text;
  v_editable text[] := array[
    'beneficiary_id','mandate_type','priority','address_line_1','address_line_2','postal_code','city',
    'comments','description','sinister_type','defect_type','affected_rooms','covering_type','appliance_type',
    'installation_type','prerequisites','scheduled_date','slot_1_at','slot_2_at','slot_3_at',
    'secondary_contact_first_name','secondary_contact_last_name','secondary_contact_mobile','secondary_contact_phone',
    'location_type','residence_type','floor','entry_code','sms_alert_enabled','email_alert_enabled','symptoms','affected_surfaces','insurer_id','import_id','insurer_file_number',
    'requester_type','requester_company_name','requester_trade_name','requester_siret',
    'requester_contact_first_name','requester_contact_last_name','requester_contact_phone',
    'requester_contact_email','requester_logo_url'];
  v_label jsonb := '{"beneficiary_id":"bénéficiaire (coordonnées)","mandate_type":"type de mandat","priority":"priorité",
    "address_line_1":"adresse","address_line_2":"complément d''adresse","postal_code":"code postal","city":"ville",
    "comments":"commentaires","description":"description","sinister_type":"type de sinistre","defect_type":"désordre",
    "affected_rooms":"pièces","covering_type":"revêtement","appliance_type":"appareils","installation_type":"installation",
    "prerequisites":"prérequis","scheduled_date":"date prévue","slot_1_at":"créneau 1","slot_2_at":"créneau 2","slot_3_at":"créneau 3",
    "secondary_contact_first_name":"prénom du second contact","secondary_contact_last_name":"nom du second contact",
    "secondary_contact_mobile":"mobile du second contact","secondary_contact_phone":"téléphone du second contact",
    "location_type":"type de lieu","residence_type":"type de logement","floor":"étage","entry_code":"code d''entrée",
    "sms_alert_enabled":"alerte SMS","email_alert_enabled":"alerte e-mail","symptoms":"symptômes","affected_surfaces":"parois",
    "insurer_id":"assureur","import_id":"import","insurer_file_number":"n° de dossier","requester_type":"organisme demandeur",
    "requester_company_name":"raison sociale","requester_trade_name":"dénomination","requester_siret":"SIRET",
    "requester_contact_first_name":"prénom du contact demandeur","requester_contact_last_name":"nom du contact demandeur",
    "requester_contact_phone":"téléphone du contact demandeur","requester_contact_email":"e-mail du contact demandeur",
    "requester_logo_url":"logo du demandeur"}'::jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;

  -- État avant modification (mandat + coordonnées du bénéficiaire), pour l'historique
  if v_id is not null then
    select to_jsonb(m), m.status::text into v_old, v_status from public.mandates m where m.id = v_id and m.insurance_org_id = v_org for update;
    if v_old is null then raise exception 'Mandat introuvable dans votre organisation'; end if;
    if v_status in ('closed', 'cancelled') then raise exception 'Ce mandat est archivé : il n''est plus modifiable'; end if;
    select jsonb_build_object('téléphone 1', b.mobile_phone, 'téléphone 2', b.landline_phone, 'e-mail', b.email) into v_ben_old
      from public.beneficiaries b where b.id = (v_old->>'beneficiary_id')::uuid;
  end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_data
    from jsonb_each(coalesce(p_data, '{}'::jsonb))
   where key = any(v_editable) and value not in ('null'::jsonb, '""'::jsonb);

  if v_data ? 'insurer_id' and not exists (select 1 from public.insurers where id = (v_data->>'insurer_id')::uuid and organization_id = v_org) then
    raise exception 'Assureur introuvable dans votre organisation';
  end if;
  if v_data ? 'import_id' and not exists (select 1 from public.mandate_imports where id = (v_data->>'import_id')::uuid and organization_id = v_org) then
    raise exception 'Import introuvable';
  end if;

  if v_data->>'beneficiary_id' is null and jsonb_typeof(p_data->'beneficiary') = 'object' then
    v_data := v_data || jsonb_build_object('beneficiary_id', public.resolve_beneficiary(p_data->'beneficiary'));
  end if;

  if v_id is null then
    if v_data->>'mandate_type' is null then raise exception 'Le type de mandat est obligatoire'; end if;
    if v_data->>'address_line_1' is null then raise exception 'L''adresse est obligatoire'; end if;
    if v_data->>'beneficiary_id' is null then raise exception 'Le bénéficiaire est obligatoire'; end if;
    select string_agg(quote_ident(k2), ', ') into v_cols from jsonb_object_keys(v_data) k2;
    execute format(
      'insert into public.mandates (%1$s, insurance_org_id, created_by_user_id, status)
       select %1$s, $2, auth.uid(), ''draft'' from jsonb_populate_record(null::public.mandates, $1)
       returning id', v_cols)
      into v_id using v_data, v_org;
  else
    if v_status not in ('draft', 'new', 'drop_pending') then
      if coalesce(p_drop, false) or coalesce(p_pending, false) or cardinality(coalesce(p_list_ids, '{}')) > 0 then
        raise exception 'Ce mandat est déjà diffusé ou attribué : utilisez « Sauvegarder » (les boutons de diffusion sont réservés aux mandats en attente)';
      end if;
      v_data := v_data - 'mandate_type' - 'import_id';
      if v_status in ('assigned', 'planning', 'in_progress', 'waiting_report') then
        v_data := v_data - 'slot_1_at' - 'slot_2_at' - 'slot_3_at' - 'scheduled_date';
      end if;
    end if;
    if v_data <> '{}'::jsonb then
      select string_agg(quote_ident(k2), ', ') into v_cols from jsonb_object_keys(v_data) k2;
      execute format(
        'update public.mandates m set (%1$s) = (select %1$s from jsonb_populate_record(m, $1)) where m.id = $2', v_cols)
        using v_data, v_id;
      -- Trace : uniquement les champs réellement modifiés
      select to_jsonb(m) into v_new from public.mandates m where m.id = v_id;
      foreach k in array (select array_agg(x) from jsonb_object_keys(v_data) x) loop
        if (v_old -> k) is distinct from (v_new -> k) then
          v_old_ch := v_old_ch || jsonb_build_object(k, v_old -> k);
          v_new_ch := v_new_ch || jsonb_build_object(k, v_new -> k);
          v_labels := v_labels || coalesce(v_label ->> k, k);
        end if;
      end loop;
    end if;
    -- Coordonnées du bénéficiaire (mises à jour par resolve_beneficiary)
    select jsonb_build_object('téléphone 1', b.mobile_phone, 'téléphone 2', b.landline_phone, 'e-mail', b.email) into v_ben_new
      from public.beneficiaries b join public.mandates m on m.beneficiary_id = b.id where m.id = v_id;
    for k in select jsonb_object_keys(coalesce(v_ben_new, '{}'::jsonb)) loop
      if (v_ben_old -> k) is distinct from (v_ben_new -> k) then
        v_old_ch := v_old_ch || jsonb_build_object('bénéficiaire ' || k, v_ben_old -> k);
        v_new_ch := v_new_ch || jsonb_build_object('bénéficiaire ' || k, v_ben_new -> k);
        v_labels := v_labels || ('bénéficiaire : ' || k);
      end if;
    end loop;
    if true then
      if cardinality(v_labels) > 0 then
        insert into public.activity_logs (user_id, organization_id, entity_type, entity_id, action, old_values_json, new_values_json)
        values (auth.uid(), v_org, 'mandate', v_id, 'mandate_updated', v_old_ch,
                v_new_ch || jsonb_build_object('comment', 'Modifié : ' || array_to_string(v_labels, ', ')));
      end if;
    end if;
  end if;

  -- Organisme demandeur : obligatoire et exclusif.
  perform public.check_mandate_requester(v_id);

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
end $function$;

create or replace function public.manager_mandate_prefill(p_mandate_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select to_jsonb(m) - 'internal_notes' || jsonb_build_object(
           'beneficiary_first_name', b.first_name, 'beneficiary_last_name', b.last_name,
           'beneficiary_mobile_phone', b.mobile_phone, 'beneficiary_landline_phone', b.landline_phone,
           'beneficiary_email', b.email, 'insurer_name', i.name)
    into v
    from public.mandates m
    left join public.beneficiaries b on b.id = m.beneficiary_id
    left join public.insurers i on i.id = m.insurer_id
   where m.id = p_mandate_id and m.insurance_org_id = public.current_user_organization_id()
     and m.status::text not in ('closed', 'cancelled');
  if v is null then raise exception 'Mandat introuvable ou archivé'; end if;
  return v;
end $function$;
