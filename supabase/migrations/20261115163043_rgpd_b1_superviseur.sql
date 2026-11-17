-- RGPD B1 — demandes RGPD réservées au superviseur (décision du 15/11/2026) :
-- un effacement est irréversible, l'export contient toutes les données d'une personne.
alter policy rgpd_requests_read on public.rgpd_requests
  using (public.is_supervisor() and organization_id = public.current_user_organization_id());

create or replace function public.rgpd_search(p_q text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_supervisor() then raise exception 'Réservé au superviseur' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_q, ''))) < 2 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x order by x->>'label') from (
    select jsonb_build_object('kind', 'beneficiaire', 'id', b.id,
             'label', concat_ws(' ', b.first_name, b.last_name),
             'contact', concat_ws(' · ', b.email, b.mobile_phone, b.landline_phone),
             'mandates', (select count(*) from mandates m where m.beneficiary_id = b.id),
             'active', (select count(*) from mandates m where m.beneficiary_id = b.id and m.status::text not in ('closed', 'cancelled'))) x
      from beneficiaries b
     where b.organization_id = v_org
       and public.search_match(concat_ws(' ', b.first_name, b.last_name, b.email, b.mobile_phone, b.landline_phone), p_q)
    union all
    select jsonb_build_object('kind', 'contact_secondaire', 'id', m.id,
             'label', concat_ws(' ', m.secondary_contact_first_name, m.secondary_contact_last_name),
             'contact', concat_ws(' · ', m.secondary_contact_mobile, m.secondary_contact_phone),
             'mandate_reference', m.reference, 'mandates', 1,
             'active', (m.status::text not in ('closed', 'cancelled'))::int)
      from mandates m
     where m.insurance_org_id = v_org
       and nullif(btrim(concat(m.secondary_contact_first_name, m.secondary_contact_last_name, m.secondary_contact_mobile)), '') is not null
       and public.search_match(concat_ws(' ', m.secondary_contact_first_name, m.secondary_contact_last_name,
                                          m.secondary_contact_mobile, m.secondary_contact_phone), p_q)
  ) s), '[]'::jsonb);
end $$;

-- Export complet (droit d'accès, portabilité) — enregistré dans le registre
create or replace function public.rgpd_beneficiary_export(p_id uuid, p_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_org uuid := public.current_user_organization_id(); v_b beneficiaries%rowtype; v jsonb;
begin
  if not public.is_supervisor() then raise exception 'Réservé au superviseur' using errcode = '42501'; end if;
  select * into v_b from beneficiaries where id = p_id and organization_id = v_org;
  if not found then raise exception 'Personne introuvable dans votre organisation'; end if;

  v := jsonb_build_object(
    'export_genere_le', now(),
    'responsable_de_traitement', (select name from organizations where id = v_org),
    'personne', jsonb_build_object('prenom', v_b.first_name, 'nom', v_b.last_name, 'email', v_b.email,
                                   'telephone_mobile', v_b.mobile_phone, 'telephone_fixe', v_b.landline_phone,
                                   'cree_le', v_b.created_at),
    'mandats', coalesce((select jsonb_agg(jsonb_build_object(
        'reference', m.reference, 'statut', public.mandate_status_label(m.status::text), 'cree_le', m.created_at,
        'adresse', concat_ws(', ', m.address_line_1, m.address_line_2, concat_ws(' ', m.postal_code, m.city)),
        'etage', m.floor, 'code_acces', m.entry_code, 'description', m.description, 'symptomes', m.symptoms,
        'commentaires', m.comments, 'date_sinistre', m.incident_date, 'creneaux', jsonb_build_array(m.slot_1_at, m.slot_2_at, m.slot_3_at),
        'contact_secondaire', nullif(concat_ws(' ', m.secondary_contact_first_name, m.secondary_contact_last_name, m.secondary_contact_mobile, m.secondary_contact_phone), ''),
        'expert', (select concat_ws(' ', e.first_name, e.last_name) from experts e where e.id = m.assigned_expert_id),
        'rapport', (select jsonb_build_object('conclusions', r.rapport_conclusions, 'preconisations', r.preconisations_reserves,
                                              'statut', r.status, 'valide_le', r.validated_at)
                      from rdf_reports r where r.mandate_id = m.id order by r.created_at desc limit 1),
        'photos', (select count(*) from report_media rm where rm.mandate_id = m.id),
        'documents', coalesce((select jsonb_agg(jsonb_build_object('nom', d.file_name, 'type', d.document_type, 'le', d.created_at))
                                 from documents d where d.mandate_id = m.id), '[]'::jsonb),
        'historique', coalesce((select jsonb_agg(jsonb_build_object('le', h.created_at, 'action', h.action_label) order by h.created_at)
                                  from mandate_history h where h.mandate_id = m.id), '[]'::jsonb)
      ) order by m.created_at) from mandates m where m.beneficiary_id = v_b.id), '[]'::jsonb),
    'destinataires', jsonb_build_array('Gestionnaires de l''assureur', 'Expert recherche de fuite missionné',
                                       'Sous-traitants techniques : Supabase (UE), WeWeb, Google Routes (temps de trajet, coordonnées uniquement)'));

  if p_request_id is not null then
    update rgpd_requests set status = 'traitee', closed_at = now(), response = 'Export transmis le ' || to_char(now(), 'DD/MM/YYYY')
     where id = p_request_id and organization_id = v_org;
  else
    insert into rgpd_requests (organization_id, request_type, subject_id, subject_label, status, response, closed_at)
    values (v_org, 'acces', v_b.id, public.rgpd_initials(v_b.first_name, v_b.last_name), 'traitee',
            'Export généré le ' || to_char(now(), 'DD/MM/YYYY'), now());
  end if;
  return v;
end $$;

-- Effacement d'un bénéficiaire
create or replace function public.rgpd_beneficiary_erase(p_id uuid, p_motif text default null, p_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_org uuid := public.current_user_organization_id(); v_b beneficiaries%rowtype; v_n int;
begin
  if not public.is_supervisor() then raise exception 'Réservé au superviseur' using errcode = '42501'; end if;
  select * into v_b from beneficiaries where id = p_id and organization_id = v_org;
  if not found then return jsonb_build_object('ok', false, 'error', 'Personne introuvable dans votre organisation.'); end if;
  if exists (select 1 from mandates where beneficiary_id = p_id and status::text not in ('closed', 'cancelled')) then
    return jsonb_build_object('ok', false, 'error', 'Un mandat est encore en cours pour cette personne : clôturez-le ou annulez-le avant l''effacement.');
  end if;

  update mandates set
    address_line_1 = 'Adresse anonymisée', address_line_2 = null, floor = null, entry_code = null,
    secondary_contact_first_name = null, secondary_contact_last_name = null, secondary_contact_mobile = null,
    secondary_contact_phone = null, secondary_contact_role = null,
    internal_notes = null, comments = null, description = null, symptoms = null,
    latitude = round(latitude, 2), longitude = round(longitude, 2), updated_at = now()
  where beneficiary_id = p_id;
  get diagnostics v_n = row_count;

  update beneficiaries set first_name = 'Anonymisé', last_name = 'Anonymisé', email = null,
         mobile_phone = null, landline_phone = null, updated_at = now()
   where id = p_id;

  if p_request_id is not null then
    update rgpd_requests set status = 'traitee', closed_at = now(),
           response = 'Effacement effectué le ' || to_char(now(), 'DD/MM/YYYY') || ' (' || v_n || ' mandat(s) anonymisé(s))'
     where id = p_request_id and organization_id = v_org;
  else
    insert into rgpd_requests (organization_id, request_type, subject_id, subject_label, status, response, closed_at)
    values (v_org, 'effacement', p_id, public.rgpd_initials(v_b.first_name, v_b.last_name), 'traitee',
            'Effacement effectué le ' || to_char(now(), 'DD/MM/YYYY') || ' (' || v_n || ' mandat(s) anonymisé(s))'
            || coalesce(' — motif : ' || nullif(btrim(p_motif), ''), ''), now());
  end if;
  insert into activity_logs (user_id, organization_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), v_org, 'user', p_id, 'rgpd_erasure', jsonb_build_object('mandates', v_n));
  return jsonb_build_object('ok', true, 'mandates', v_n);
end $$;

-- Registre : ajout manuel, clôture, liste
create or replace function public.rgpd_request_add(p_type text, p_subject_label text, p_channel text default null,
  p_received_at date default current_date, p_subject_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if not public.is_supervisor() then raise exception 'Réservé au superviseur' using errcode = '42501'; end if;
  if p_type not in ('acces', 'effacement', 'rectification', 'opposition', 'limitation', 'portabilite', 'autre') then
    return jsonb_build_object('ok', false, 'error', 'Type de demande inconnu.');
  end if;
  insert into rgpd_requests (organization_id, request_type, subject_id, subject_label, channel, received_at, due_at)
  values (public.current_user_organization_id(), p_type, p_subject_id, nullif(btrim(p_subject_label), ''),
          nullif(btrim(p_channel), ''), coalesce(p_received_at, current_date),
          (coalesce(p_received_at, current_date) + interval '1 month')::date)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.rgpd_request_close(p_id uuid, p_status text, p_response text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_supervisor() then raise exception 'Réservé au superviseur' using errcode = '42501'; end if;
  if p_status not in ('traitee', 'refusee') then return jsonb_build_object('ok', false, 'error', 'Statut invalide.'); end if;
  if p_status = 'refusee' and nullif(btrim(p_response), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Un refus doit être motivé (art. 12.4).');
  end if;
  update rgpd_requests set status = p_status, response = nullif(btrim(p_response), ''), closed_at = now()
   where id = p_id and organization_id = public.current_user_organization_id();
  return jsonb_build_object('ok', found);
end $$;

create or replace function public.rgpd_requests_list()
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not public.is_supervisor() then raise exception 'Réservé au superviseur' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id, 'type', r.request_type, 'personne', r.subject_label, 'canal', r.channel,
      'recue_le', r.received_at, 'echeance', r.due_at, 'statut', r.status, 'reponse', r.response,
      'en_retard', r.status = 'ouverte' and r.due_at < current_date,
      'jours_restants', case when r.status = 'ouverte' then r.due_at - current_date end,
      'cloturee_le', r.closed_at) order by (r.status = 'ouverte') desc, r.due_at, r.created_at desc)
    from rgpd_requests r where r.organization_id = public.current_user_organization_id()), '[]'::jsonb);
end $$;

revoke execute on function public.rgpd_search(text), public.rgpd_beneficiary_export(uuid, uuid),
  public.rgpd_beneficiary_erase(uuid, text, uuid), public.rgpd_request_add(text, text, text, date, uuid),
  public.rgpd_request_close(uuid, text, text), public.rgpd_requests_list() from public, anon;
grant execute on function public.rgpd_search(text), public.rgpd_beneficiary_export(uuid, uuid),
  public.rgpd_beneficiary_erase(uuid, text, uuid), public.rgpd_request_add(text, text, text, date, uuid),
  public.rgpd_request_close(uuid, text, text), public.rgpd_requests_list() to authenticated, service_role;
