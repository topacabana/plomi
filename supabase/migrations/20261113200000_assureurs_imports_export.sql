-- Assureurs (clients de l'organisation), traçage des imports CSV,
-- numéro de dossier assureur sur les mandats et export des mandats.

-- ============ Assureurs ============
create table if not exists public.insurers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  logo_url text,
  -- Localisation (siège / agence)
  address_line_1 text,
  postal_code text,
  city text,
  latitude numeric,
  longitude numeric,
  -- Zone de chalandise : ville centre + rayon
  catchment_city text,
  catchment_postal_code text,
  catchment_latitude numeric,
  catchment_longitude numeric,
  catchment_radius_km integer check (catchment_radius_km is null or catchment_radius_km between 1 and 1000),
  -- Contact
  contact_name text,
  contact_email text,
  contact_phone text,
  notes text,
  archived_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists insurers_org_name_uidx on public.insurers (organization_id, lower(name)) where archived_at is null;
create index if not exists insurers_org_idx on public.insurers (organization_id);

alter table public.insurers enable row level security;
drop policy if exists "gestionnaire : assureurs de son organisation" on public.insurers;
create policy "gestionnaire : assureurs de son organisation" on public.insurers
  for select using (public.is_manager() and organization_id = public.current_user_organization_id());

-- ============ Imports CSV ============
create table if not exists public.mandate_imports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  insurer_id uuid references public.insurers(id) on delete set null,
  file_name text,
  rows_total integer not null default 0,
  rows_imported integer not null default 0,
  rows_failed integer not null default 0,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists mandate_imports_org_idx on public.mandate_imports (organization_id, created_at desc);
create index if not exists mandate_imports_insurer_idx on public.mandate_imports (insurer_id);

alter table public.mandate_imports enable row level security;
drop policy if exists "gestionnaire : imports de son organisation" on public.mandate_imports;
create policy "gestionnaire : imports de son organisation" on public.mandate_imports
  for select using (public.is_manager() and organization_id = public.current_user_organization_id());

-- ============ Mandats : assureur, import, n° de dossier assureur ============
alter table public.mandates add column if not exists insurer_id uuid references public.insurers(id) on delete set null;
alter table public.mandates add column if not exists import_id uuid references public.mandate_imports(id) on delete set null;
alter table public.mandates add column if not exists insurer_file_number text;
create index if not exists mandates_insurer_idx on public.mandates (insurer_id);
create index if not exists mandates_import_idx on public.mandates (import_id);
-- Un n° de dossier est unique chez un assureur (hors mandats annulés)
create unique index if not exists mandates_insurer_file_number_uidx
  on public.mandates (insurer_id, lower(btrim(insurer_file_number)))
  where insurer_id is not null and insurer_file_number is not null and status <> 'cancelled';

-- ============ Logos (stockage public, dossier = organisation) ============
insert into storage.buckets (id, name, public) values ('insurer-logos', 'insurer-logos', true)
on conflict (id) do nothing;
drop policy if exists "insurer-logos : envoi par un gestionnaire" on storage.objects;
create policy "insurer-logos : envoi par un gestionnaire" on storage.objects for insert
  with check (bucket_id = 'insurer-logos' and public.is_manager()
              and (storage.foldername(name))[1] = public.current_user_organization_id()::text);
drop policy if exists "insurer-logos : remplacement par un gestionnaire" on storage.objects;
create policy "insurer-logos : remplacement par un gestionnaire" on storage.objects for update
  using (bucket_id = 'insurer-logos' and public.is_manager()
         and (storage.foldername(name))[1] = public.current_user_organization_id()::text);

-- ============ RPC assureurs ============
-- Création / modification d'un assureur. Renvoie son id.
create or replace function public.insurer_save(p_id uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_id uuid := p_id;
  v_name text := nullif(btrim(p_data->>'name'), '');
  v_radius integer := nullif(p_data->>'catchment_radius_km', '')::numeric::integer;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if v_name is null then raise exception 'Le nom de l''assureur est obligatoire'; end if;
  if exists (select 1 from insurers where organization_id = v_org and lower(name) = lower(v_name)
             and archived_at is null and id is distinct from v_id) then
    raise exception 'Un assureur porte déjà ce nom';
  end if;

  if v_id is null then
    insert into insurers (organization_id, name) values (v_org, v_name) returning id into v_id;
  elsif not exists (select 1 from insurers where id = v_id and organization_id = v_org) then
    raise exception 'Assureur introuvable';
  end if;

  update insurers set
    name = v_name,
    logo_url = nullif(btrim(p_data->>'logo_url'), ''),
    address_line_1 = nullif(btrim(p_data->>'address_line_1'), ''),
    postal_code = nullif(btrim(p_data->>'postal_code'), ''),
    city = nullif(btrim(p_data->>'city'), ''),
    latitude = nullif(p_data->>'latitude', '')::numeric,
    longitude = nullif(p_data->>'longitude', '')::numeric,
    catchment_city = nullif(btrim(p_data->>'catchment_city'), ''),
    catchment_postal_code = nullif(btrim(p_data->>'catchment_postal_code'), ''),
    catchment_latitude = nullif(p_data->>'catchment_latitude', '')::numeric,
    catchment_longitude = nullif(p_data->>'catchment_longitude', '')::numeric,
    catchment_radius_km = v_radius,
    contact_name = nullif(btrim(p_data->>'contact_name'), ''),
    contact_email = nullif(btrim(p_data->>'contact_email'), ''),
    contact_phone = nullif(btrim(p_data->>'contact_phone'), ''),
    notes = nullif(btrim(p_data->>'notes'), ''),
    updated_at = now()
  where id = v_id;
  return v_id;
end $$;

-- Liste des assureurs avec leurs compteurs.
create or replace function public.insurers_list()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
    select to_jsonb(i) || jsonb_build_object(
      'mandates_total', (select count(*) from mandates m where m.insurer_id = i.id),
      'mandates_active', (select count(*) from mandates m where m.insurer_id = i.id and m.status not in ('closed','cancelled')),
      'imports_total', (select count(*) from mandate_imports mi where mi.insurer_id = i.id),
      'last_import_at', (select max(created_at) from mandate_imports mi where mi.insurer_id = i.id)
    ) as x
    from insurers i
    where public.is_manager() and i.organization_id = public.current_user_organization_id() and i.archived_at is null
  ) s;
$$;

-- Fiche détaillée : assureur, compteurs, imports, derniers mandats.
create or replace function public.insurer_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select to_jsonb(i) || jsonb_build_object(
    'stats', jsonb_build_object(
      'total', (select count(*) from mandates m where m.insurer_id = i.id),
      'active', (select count(*) from mandates m where m.insurer_id = i.id and m.status not in ('closed','cancelled')),
      'closed', (select count(*) from mandates m where m.insurer_id = i.id and m.status = 'closed'),
      'imports', (select count(*) from mandate_imports mi where mi.insurer_id = i.id)
    ),
    'imports', coalesce((select jsonb_agg(jsonb_build_object(
        'id', mi.id, 'file_name', mi.file_name, 'created_at', mi.created_at,
        'rows_total', mi.rows_total, 'rows_imported', mi.rows_imported, 'rows_failed', mi.rows_failed,
        'created_by_name', (select trim(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')) from user_profiles u where u.id = mi.created_by)
      ) order by mi.created_at desc) from mandate_imports mi where mi.insurer_id = i.id), '[]'::jsonb),
    'mandates', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'reference', m.reference, 'insurer_file_number', m.insurer_file_number,
        'status', m.status, 'mandate_type', m.mandate_type, 'city', m.city, 'created_at', m.created_at,
        'beneficiary', (select trim(coalesce(b.last_name,'') || ' ' || coalesce(b.first_name,'')) from beneficiaries b where b.id = m.beneficiary_id)
      ) order by m.created_at desc) from (select * from mandates where insurer_id = i.id order by created_at desc limit 50) m), '[]'::jsonb)
  ) into v
  from insurers i where i.id = p_id and i.organization_id = public.current_user_organization_id();
  if v is null then raise exception 'Assureur introuvable'; end if;
  return v;
end $$;

-- Archive (masque) un assureur ; ses mandats sont conservés.
create or replace function public.insurer_archive(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  update insurers set archived_at = now(), updated_at = now()
   where id = p_id and organization_id = public.current_user_organization_id();
  if not found then raise exception 'Assureur introuvable'; end if;
end $$;

-- ============ RPC imports ============
create or replace function public.mandate_import_start(p_insurer_id uuid, p_file_name text, p_rows_total integer)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if not exists (select 1 from insurers where id = p_insurer_id and organization_id = public.current_user_organization_id() and archived_at is null) then
    raise exception 'Choisissez un assureur valide';
  end if;
  insert into mandate_imports (organization_id, insurer_id, file_name, rows_total)
  values (public.current_user_organization_id(), p_insurer_id, p_file_name, coalesce(p_rows_total, 0))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.mandate_import_finish(p_id uuid, p_imported integer, p_failed integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  update mandate_imports set rows_imported = rows_imported + coalesce(p_imported, 0),
         rows_failed = coalesce(p_failed, 0), finished_at = now()
   where id = p_id and organization_id = public.current_user_organization_id();
end $$;

-- N° de dossier déjà utilisés chez un assureur (contrôle de doublon avant import).
create or replace function public.insurer_existing_file_numbers(p_insurer_id uuid, p_numbers text[])
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct m.insurer_file_number), '{}')
    from mandates m
   where public.is_manager()
     and m.insurance_org_id = public.current_user_organization_id()
     and m.insurer_id = p_insurer_id and m.status <> 'cancelled'
     and lower(btrim(m.insurer_file_number)) = any (select lower(btrim(x)) from unnest(p_numbers) x);
$$;

-- Liste des imports (pour la popup de téléchargement).
create or replace function public.mandate_imports_list(p_insurer_id uuid default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', mi.id, 'file_name', mi.file_name, 'created_at', mi.created_at,
      'insurer_id', mi.insurer_id, 'insurer_name', i.name,
      'rows_imported', mi.rows_imported, 'rows_total', mi.rows_total,
      'label', coalesce(i.name || ' · ', '') || coalesce(mi.file_name, 'Import') || ' · ' || to_char(mi.created_at at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI') || ' (' || mi.rows_imported || ')'
    ) order by mi.created_at desc), '[]'::jsonb)
  from mandate_imports mi left join insurers i on i.id = mi.insurer_id
  where public.is_manager() and mi.organization_id = public.current_user_organization_id()
    and (p_insurer_id is null or mi.insurer_id = p_insurer_id);
$$;

-- ============ Export ============
-- Mandats (et leurs rapports) filtrés par période de création, imports et/ou assureur.
create or replace function public.mandates_export(p_from date default null, p_to date default null,
                                                  p_import_ids uuid[] default null, p_insurer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_org uuid := public.current_user_organization_id(); v jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  with sel as (
    select m.* from mandates m
     where m.insurance_org_id = v_org
       and (p_from is null or (m.created_at at time zone 'Europe/Paris')::date >= p_from)
       and (p_to is null or (m.created_at at time zone 'Europe/Paris')::date <= p_to)
       and (coalesce(cardinality(p_import_ids), 0) = 0 or m.import_id = any (p_import_ids))
       and (p_insurer_id is null or m.insurer_id = p_insurer_id)
  )
  select jsonb_build_object(
    'mandates', coalesce((select jsonb_agg(jsonb_build_object(
        'Référence', s.reference,
        'N° dossier assureur', s.insurer_file_number,
        'Assureur', i.name,
        'Import', mi.file_name,
        'Statut', s.status,
        'Type', upper(s.mandate_type::text),
        'Priorité', s.priority,
        'Nom', b.last_name, 'Prénom', b.first_name,
        'Téléphone mobile', b.mobile_phone, 'Téléphone fixe', b.landline_phone, 'Email', b.email,
        'Adresse', s.address_line_1, 'Complément', s.address_line_2, 'Code postal', s.postal_code, 'Ville', s.city,
        'Type de lieu', s.location_type, 'Type de résidence', s.residence_type, 'Étage', s.floor,
        'Type de sinistre', array_to_string(s.sinister_type, ', '), 'Type de défaut', s.defect_type,
        'Pièces', array_to_string(s.affected_rooms, ', '), 'Surfaces', array_to_string(s.affected_surfaces, ', '),
        'Description', s.description, 'Symptômes', s.symptoms, 'Commentaires', s.comments,
        'Expert', nullif(trim(coalesce(s.expert_first_name,'') || ' ' || coalesce(s.expert_last_name,'')), ''),
        'Créé le', to_char(s.created_at at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI'),
        'Date prévue', to_char(s.scheduled_date, 'DD/MM/YYYY'),
        'Créneau retenu', to_char(s.selected_slot_at at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI'),
        'Arrivée sur site', to_char(s.arrived_at at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI'),
        'Clôturé le', to_char(s.closed_at at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI'),
        'Type de clôture', s.closure_type
      ) order by s.created_at) from sel s
        left join beneficiaries b on b.id = s.beneficiary_id
        left join insurers i on i.id = s.insurer_id
        left join mandate_imports mi on mi.id = s.import_id), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(jsonb_build_object(
        'Référence', s.reference,
        'N° dossier assureur', s.insurer_file_number,
        'Statut rapport', r.status,
        'Soumis le', to_char(r.submitted_at at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI'),
        'Validé le', to_char(r.validated_at at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI'),
        'Pièce investiguée', r.inspection_piece_investigee,
        'Infiltration constatée', case when r.infiltration_constatee then 'Oui' when r.infiltration_non_constatee then 'Non' end,
        'Moisissure', case when r.presence_moisissure then 'Oui' end,
        'Revêtement endommagé', case when r.peinture_revetement_endommage then 'Oui' end,
        'Commentaires inspection', r.inspection_commentaires,
        'Test colorant', r.colorant_result,
        'Test fluorescéine', r.fluorine_result,
        'Gaz traceur', case when r.gaz_detecte then 'Détecté' when r.gaz_non_detecte then 'Non détecté' end,
        'Gaz traceur – résultat', r.gaz_traceur_result,
        'Sonde – mesure', r.sonde_reading, 'Sonde – unité', r.sonde_unit, 'Sonde – emplacement', r.sonde_location,
        'Hypothèses', array_to_string(r.hypotheses, ', '),
        'Conclusions', r.rapport_conclusions,
        'Préconisations / réserves', r.preconisations_reserves,
        'Rapport PDF', r.pdf_url
      ) order by s.created_at) from sel s join rdf_reports r on r.mandate_id = s.id), '[]'::jsonb)
      || coalesce((select jsonb_agg(jsonb_build_object(
        'Référence', s.reference,
        'N° dossier assureur', s.insurer_file_number,
        'Statut rapport', ir.status,
        'Soumis le', to_char(ir.submitted_at at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI'),
        'Validé le', to_char(ir.accepted_at at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI'),
        'Conclusions', ir.expert_comments,
        'Rapport PDF', ir.rapport_pdf_url
      ) order by s.created_at) from sel s join investigation_reports ir on ir.mandate_id = s.id), '[]'::jsonb)
  ) into v;
  return v;
end $$;

grant execute on function public.insurer_save(uuid, jsonb), public.insurers_list(), public.insurer_detail(uuid),
  public.insurer_archive(uuid), public.mandate_import_start(uuid, text, integer), public.mandate_import_finish(uuid, integer, integer),
  public.insurer_existing_file_numbers(uuid, text[]), public.mandate_imports_list(uuid),
  public.mandates_export(date, date, uuid[], uuid) to authenticated;

-- ============ save_mandate_form : nouveaux champs modifiables ============
do $$
declare d text; n text;
begin
  select pg_get_functiondef('public.save_mandate_form(uuid,jsonb,boolean,uuid[],boolean)'::regprocedure) into d;
  if position('insurer_file_number' in d) = 0 then
    n := regexp_replace(d, '''email_alert_enabled'',\s*''symptoms'',\s*''affected_surfaces''\]',
                        '''email_alert_enabled'',''symptoms'',''affected_surfaces'',''insurer_id'',''import_id'',''insurer_file_number'']');
    if n = d then raise exception 'save_mandate_form : liste des champs introuvable'; end if;
    -- Contrôle d'appartenance de l'assureur et de l'import à l'organisation
    n := regexp_replace(n, '(  if v_data->>''beneficiary_id'' is null and jsonb_typeof)',
      E'  if v_data ? ''insurer_id'' and not exists (select 1 from public.insurers where id = (v_data->>''insurer_id'')::uuid and organization_id = v_org) then\n    raise exception ''Assureur introuvable dans votre organisation'';\n  end if;\n  if v_data ? ''import_id'' and not exists (select 1 from public.mandate_imports where id = (v_data->>''import_id'')::uuid and organization_id = v_org) then\n    raise exception ''Import introuvable'';\n  end if;\n\n\\1');
    execute n;
  end if;
end $$;
