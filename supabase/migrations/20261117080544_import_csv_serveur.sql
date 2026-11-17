-- Import CSV côté serveur : la lecture, le découpage, la correspondance des colonnes,
-- la conversion des valeurs et les contrôles passent du JavaScript WeWeb à PostgreSQL.
-- Le front lit le fichier avec l'élément natif ww-input-file (contenu en base64)
-- et appelle ces fonctions avec l'action native « Call Postgres function ».
--
--   csv_import_analyze(nom, base64, assureur) : décode, découpe, associe les colonnes par nom
--   csv_import_build(état)                    : convertit et valide chaque ligne (mêmes règles que le formulaire)

-- ---------- Outils ----------

-- Minuscules, sans accents, sans ponctuation (comparaison des en-têtes et des valeurs).
create or replace function public.csv_normalize(p text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select btrim(regexp_replace(
           lower(translate(coalesce(p, ''),
             'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ',
             'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY')),
           '[^a-z0-9]+', ' ', 'g'));
$$;

-- Dictionnaire des champs du formulaire de création de mandat, dans l'ordre du formulaire.
-- key : clé envoyée à save_mandate_form (beneficiary.* = bénéficiaire) ; label : en-tête du modèle CSV ;
-- type : text | enum_type | enum_priority | list | date | datetime | bool | phone ; aliases : autres noms reconnus.
create or replace function public.csv_import_fields()
returns jsonb
language sql
immutable
set search_path to 'public'
as $$
select '[
 {"key":"insurer_file_number","label":"N° dossier assureur","type":"text","aliases":["numero dossier assureur","n dossier","no dossier","num dossier","numero dossier","numero de dossier","dossier","reference assureur","ref assureur","reference dossier","ref dossier","numero sinistre","n sinistre","no sinistre","ref sinistre","reference sinistre","n dossier sinistre","insurer file number","claim number"]},
 {"key":"mandate_type","label":"Type de mandat","type":"enum_type","aliases":["type","type mandat","type d expertise","type expertise","mandate type"]},
 {"key":"priority","label":"Priorité","type":"enum_priority","aliases":["priorite","urgence","priority"]},
 {"key":"beneficiary.last_name","label":"Nom","type":"text","aliases":["nom beneficiaire","nom du beneficiaire","nom assure","nom de famille","last name","lastname"]},
 {"key":"beneficiary.first_name","label":"Prénom","type":"text","aliases":["prenom beneficiaire","prenom du beneficiaire","prenom assure","first name","firstname"]},
 {"key":"beneficiary.mobile_phone","label":"Téléphone mobile","type":"phone","aliases":["mobile","portable","tel mobile","tel portable","telephone portable","telephone","tel","mobile phone","phone"]},
 {"key":"beneficiary.landline_phone","label":"Téléphone fixe","type":"phone","aliases":["fixe","tel fixe","telephone fixe","landline"]},
 {"key":"beneficiary.email","label":"Email","type":"text","aliases":["e mail","mail","courriel","adresse mail","adresse email","adresse e mail"]},
 {"key":"address_line_1","label":"Adresse","type":"text","aliases":["adresse ligne 1","adresse 1","rue","voie","address","adresse du sinistre"]},
 {"key":"address_line_2","label":"Complément d''adresse","type":"text","aliases":["adresse ligne 2","adresse 2","complement","complement adresse","batiment"]},
 {"key":"postal_code","label":"Code postal","type":"text","aliases":["cp","code postale","zip","postal code"]},
 {"key":"city","label":"Ville","type":"text","aliases":["commune","localite","city"]},
 {"key":"location_type","label":"Type de lieu","type":"text","aliases":["lieu","type lieu"]},
 {"key":"residence_type","label":"Type de résidence","type":"text","aliases":["residence","type residence","type de logement","logement"]},
 {"key":"floor","label":"Étage","type":"text","aliases":["etage","niveau"]},
 {"key":"entry_code","label":"Code d''entrée","type":"text","aliases":["code entree","digicode","code porte","code acces"]},
 {"key":"sinister_type","label":"Type de sinistre","type":"list","aliases":["sinistre","types de sinistre","nature du sinistre"]},
 {"key":"defect_type","label":"Type de défaut","type":"text","aliases":["defaut","type defaut","nature du defaut"]},
 {"key":"affected_rooms","label":"Pièces concernées","type":"list","aliases":["pieces","pieces touchees","pieces sinistrees","piece"]},
 {"key":"affected_surfaces","label":"Surfaces concernées","type":"list","aliases":["surfaces","surfaces touchees","surface"]},
 {"key":"covering_type","label":"Revêtements","type":"list","aliases":["revetement","type de revetement","types de revetement"]},
 {"key":"appliance_type","label":"Appareils","type":"list","aliases":["appareil","type d appareil","electromenager"]},
 {"key":"installation_type","label":"Installations","type":"list","aliases":["installation","type d installation"]},
 {"key":"symptoms","label":"Symptômes","type":"text","aliases":["symptome","constat","constats"]},
 {"key":"description","label":"Description","type":"text","aliases":["descriptif","detail","details"]},
 {"key":"prerequisites","label":"Prérequis","type":"list","aliases":["prerequis","pre requis"]},
 {"key":"scheduled_date","label":"Date prévue","type":"date","aliases":["date","date souhaitee","date d intervention","date rdv","date de rendez vous"]},
 {"key":"slot_1_at","label":"Créneau 1","type":"datetime","aliases":["creneau1","disponibilite 1","dispo 1"]},
 {"key":"slot_2_at","label":"Créneau 2","type":"datetime","aliases":["creneau2","disponibilite 2","dispo 2"]},
 {"key":"slot_3_at","label":"Créneau 3","type":"datetime","aliases":["creneau3","disponibilite 3","dispo 3"]},
 {"key":"secondary_contact_last_name","label":"Nom contact secondaire","type":"text","aliases":["nom contact 2","nom second contact","contact secondaire nom"]},
 {"key":"secondary_contact_first_name","label":"Prénom contact secondaire","type":"text","aliases":["prenom contact 2","prenom second contact","contact secondaire prenom"]},
 {"key":"secondary_contact_mobile","label":"Mobile contact secondaire","type":"phone","aliases":["mobile contact 2","portable contact secondaire","contact secondaire mobile"]},
 {"key":"secondary_contact_phone","label":"Fixe contact secondaire","type":"phone","aliases":["telephone contact secondaire","tel contact 2","contact secondaire telephone"]},
 {"key":"sms_alert_enabled","label":"Alerte SMS","type":"bool","aliases":["sms","alertes sms","notification sms"]},
 {"key":"email_alert_enabled","label":"Alerte email","type":"bool","aliases":["alerte mail","alertes email","notification email","notification mail"]},
 {"key":"comments","label":"Commentaires","type":"text","aliases":["commentaire","remarque","remarques","notes","note"]}
]'::jsonb;
$$;

-- Découpe un texte CSV en lignes et cellules (guillemets, "" échappés, retours à la ligne dans une cellule).
create or replace function public.csv_parse(p_text text, p_delim text)
returns jsonb
language plpgsql
immutable
set search_path to 'public'
as $$
declare
  ch text[] := regexp_split_to_array(coalesce(p_text, ''), '');
  n int := coalesce(array_length(ch, 1), 0);
  i int := 1;
  c text;
  cell text := '';
  row_cells text[] := '{}';
  rows jsonb := '[]'::jsonb;
  in_q boolean := false;
begin
  while i <= n loop
    c := ch[i];
    if in_q then
      if c = '"' and i < n and ch[i + 1] = '"' then cell := cell || '"'; i := i + 1;
      elsif c = '"' then in_q := false;
      else cell := cell || c;
      end if;
    elsif c = '"' then in_q := true;
    elsif c = p_delim then row_cells := row_cells || cell; cell := '';
    elsif c = E'\n' or c = E'\r' then
      if c = E'\r' and i < n and ch[i + 1] = E'\n' then i := i + 1; end if;
      row_cells := row_cells || cell;
      rows := rows || jsonb_build_array(to_jsonb(row_cells));
      row_cells := '{}'; cell := '';
    else cell := cell || c;
    end if;
    i := i + 1;
  end loop;
  if cell <> '' or cardinality(row_cells) > 0 then
    row_cells := row_cells || cell;
    rows := rows || jsonb_build_array(to_jsonb(row_cells));
  end if;
  return rows;
end $$;

-- ---------- Analyse du fichier ----------

create or replace function public.csv_import_analyze(p_file_name text, p_content_base64 text, p_insurer_id text default '')
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public'
as $$
declare
  v_fields jsonb := public.csv_import_fields();
  v_light jsonb;
  v_b64 text := coalesce(p_content_base64, '');
  v_bytes bytea;
  v_text text;
  v_first text;
  v_delim text := ';';
  v_cnt_semi int; v_cnt_comma int; v_cnt_tab int;
  v_table jsonb; v_header jsonb; v_raw jsonb;
  v_lookup jsonb := '{}'::jsonb;
  f jsonb; nm text;
  v_columns jsonb := '[]'::jsonb;
  v_used text[] := '{}';
  v_csv text; v_key text; v_sample text;
  j int; k int;
  v_insurer text := coalesce(p_insurer_id, '');
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('key', x->>'key', 'label', x->>'label', 'type', x->>'type')), '[]'::jsonb)
    into v_light from jsonb_array_elements(v_fields) x;

  begin
    if v_b64 like 'data:%' then v_b64 := substr(v_b64, position(',' in v_b64) + 1); end if;
    if length(v_b64) > 7000000 then raise exception 'Fichier trop lourd : 5 Mo maximum.'; end if;
    v_bytes := decode(regexp_replace(v_b64, '\s', '', 'g'), 'base64');
    -- UTF-8 d'abord, puis Windows-1252 (export Excel) si l'UTF-8 est invalide.
    begin
      v_text := convert_from(v_bytes, 'UTF8');
    exception when others then
      v_text := convert_from(v_bytes, 'WIN1252');
    end;
    v_text := regexp_replace(v_text, '^' || chr(65279), '');

    -- Séparateur : le plus fréquent hors guillemets sur la première ligne (; par défaut).
    v_first := split_part(replace(v_text, E'\r', ''), E'\n', 1);
    v_first := regexp_replace(v_first, '"[^"]*"', '', 'g');
    v_cnt_semi := length(v_first) - length(replace(v_first, ';', ''));
    v_cnt_comma := length(v_first) - length(replace(v_first, ',', ''));
    v_cnt_tab := length(v_first) - length(replace(v_first, E'\t', ''));
    if v_cnt_comma > v_cnt_semi and v_cnt_comma >= v_cnt_tab then v_delim := ',';
    elsif v_cnt_tab > v_cnt_semi and v_cnt_tab > v_cnt_comma then v_delim := E'\t';
    end if;

    -- Lignes non vides.
    select coalesce(jsonb_agg(r order by o), '[]'::jsonb) into v_table
      from jsonb_array_elements(public.csv_parse(v_text, v_delim)) with ordinality t(r, o)
     where exists (select 1 from jsonb_array_elements_text(r) c where btrim(c) <> '');
    if jsonb_array_length(v_table) < 2 then
      raise exception 'Le fichier ne contient pas de ligne de données sous l''en-tête.';
    end if;
    v_header := v_table->0;
    select coalesce(jsonb_agg(r order by o), '[]'::jsonb) into v_raw
      from jsonb_array_elements(v_table) with ordinality t(r, o) where o > 1;

    -- Table « nom normalisé » -> clé du champ (le premier gagne).
    for f in select * from jsonb_array_elements(v_fields) loop
      for nm in
        select f->>'label' union all select f->>'key' union all select replace(f->>'key', 'beneficiary.', '')
        union all select jsonb_array_elements_text(f->'aliases')
      loop
        nm := public.csv_normalize(nm);
        if nm <> '' and not v_lookup ? nm then v_lookup := v_lookup || jsonb_build_object(nm, f->>'key'); end if;
      end loop;
    end loop;

    -- Association automatique des colonnes par nom (et non par position).
    for j in 0 .. jsonb_array_length(v_header) - 1 loop
      v_csv := btrim(v_header->>j);
      if v_csv = '' then v_csv := 'Colonne ' || (j + 1); end if;
      v_key := coalesce(v_lookup->>public.csv_normalize(v_csv), '');
      if v_key <> '' and v_key = any(v_used) then v_key := ''; end if;
      if v_key <> '' then v_used := v_used || v_key; end if;
      v_sample := '';
      for k in 0 .. jsonb_array_length(v_raw) - 1 loop
        if btrim(coalesce(v_raw->k->>j, '')) <> '' then v_sample := btrim(v_raw->k->>j); exit; end if;
      end loop;
      v_columns := v_columns || jsonb_build_object('index', j, 'csv', v_csv, 'key', v_key, 'auto', v_key <> '', 'sample', v_sample);
    end loop;

    return jsonb_build_object('fileName', p_file_name, 'delimiter', v_delim, 'fields', v_light, 'columns', v_columns,
      'raw', v_raw, 'rows', '[]'::jsonb, 'insurerId', v_insurer, 'importId', '', 'importing', false, 'done', false, 'error', '');
  exception when others then
    if sqlerrm = 'Réservé aux gestionnaires' then raise; end if;
    return jsonb_build_object('fileName', p_file_name, 'fields', v_light, 'columns', '[]'::jsonb, 'raw', '[]'::jsonb,
      'rows', '[]'::jsonb, 'insurerId', v_insurer, 'importId', '', 'importing', false, 'done', false,
      'error', case when sqlerrm like 'invalid%base64%' or sqlerrm like '%base64%' then 'Fichier illisible.' else sqlerrm end);
  end;
end $$;

-- ---------- Conversion des valeurs ----------

create or replace function public.csv_to_date(p text)
returns text
language plpgsql
immutable
set search_path to 'public'
as $$
declare m text[];
begin
  m := regexp_match(p, '^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})');
  if m is not null then
    return (case when length(m[3]) = 2 then '20' || m[3] else m[3] end) || '-' || lpad(m[2], 2, '0') || '-' || lpad(m[1], 2, '0');
  end if;
  m := regexp_match(p, '^(\d{4})-(\d{1,2})-(\d{1,2})');
  if m is not null then return m[1] || '-' || lpad(m[2], 2, '0') || '-' || lpad(m[3], 2, '0'); end if;
  return null;
end $$;

-- Date + heure (ex. « 12/11/2026 14h30 », 9h00 par défaut), heure de Paris, renvoyée en ISO UTC.
create or replace function public.csv_to_datetime(p text)
returns timestamptz
language plpgsql
immutable
set search_path to 'public'
as $$
declare v_clean text := btrim(replace(p, 'T', ' ')); v_day text; t text[]; d text[];
begin
  v_day := public.csv_to_date(v_clean);
  if v_day is null then return null; end if;
  t := regexp_match(regexp_replace(v_clean, '^\S+', ''), '(\d{1,2})\s*[:hH]\s*(\d{2})?');
  d := string_to_array(v_day, '-');
  return make_timestamptz(d[1]::int, d[2]::int, d[3]::int,
    coalesce(t[1]::int, 9), coalesce(t[2]::int, 0), 0, 'Europe/Paris');
exception when others then
  return null;
end $$;

-- ---------- Construction des lignes ----------

create or replace function public.csv_import_build(p_state jsonb)
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public'
as $$
declare
  s jsonb := coalesce(p_state, '{}'::jsonb);
  v_fields jsonb := coalesce(s->'fields', '[]'::jsonb);
  v_raw jsonb := coalesce(s->'raw', '[]'::jsonb);
  v_mapping jsonb := '[]'::jsonb;
  v_ignored jsonb := '[]'::jsonb;
  v_missing jsonb := '[]'::jsonb;
  v_required text[] := array['mandate_type', 'address_line_1', 'beneficiary.last_name', 'beneficiary.first_name'];
  v_type_labels jsonb := '{"visio":"Visio","rdf":"RDF","rdfs":"RDFS"}';
  v_prio_labels jsonb := '{"low":"Basse","medium":"Moyenne","high":"Haute","critical":"Critique"}';
  c jsonb; fld jsonb; col jsonb; cells jsonb;
  v_file_index int; v_existing text[] := '{}'; v_numbers text[];
  v_seen_numbers jsonb := '{}'; v_seen jsonb := '{}';
  v_rows jsonb := '[]'::jsonb;
  i int; v_line int;
  data jsonb; ben jsonb; shown jsonb; errs jsonb; warns jsonb;
  raw text; val jsonb; disp text; n text; ts timestamptz; dupkey text; num text;
  k text;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;

  -- Colonnes associées à un champ / colonnes ignorées.
  for c in select * from jsonb_array_elements(coalesce(s->'columns', '[]'::jsonb)) loop
    select x into fld from jsonb_array_elements(v_fields) x where x->>'key' = c->>'key' limit 1;
    if coalesce(c->>'key', '') <> '' and fld is not null then
      v_mapping := v_mapping || (c || jsonb_build_object('label', fld->>'label', 'type', fld->>'type'));
    elsif coalesce(c->>'key', '') = '' then
      v_ignored := v_ignored || to_jsonb(c->>'csv');
    end if;
    fld := null;
  end loop;

  -- Champs obligatoires sans colonne.
  foreach k in array v_required loop
    if not exists (select 1 from jsonb_array_elements(v_mapping) m where m->>'key' = k) then
      v_missing := v_missing || to_jsonb(coalesce((select x->>'label' from jsonb_array_elements(v_fields) x where x->>'key' = k), k));
    end if;
  end loop;

  -- N° de dossier assureur : numéros déjà utilisés chez l'assureur choisi.
  select (m->>'index')::int into v_file_index from jsonb_array_elements(v_mapping) m where m->>'key' = 'insurer_file_number' limit 1;
  if v_file_index is not null and coalesce(s->>'insurerId', '') <> '' then
    select array_agg(distinct btrim(r->>v_file_index)) into v_numbers
      from jsonb_array_elements(v_raw) r where btrim(coalesce(r->>v_file_index, '')) <> '';
    if cardinality(coalesce(v_numbers, '{}')) > 0 then
      select coalesce(array_agg(lower(btrim(x))), '{}') into v_existing
        from unnest(public.insurer_existing_file_numbers((s->>'insurerId')::uuid, v_numbers)) x;
    end if;
  end if;

  -- Une ligne du CSV -> un mandat.
  for i in 0 .. jsonb_array_length(v_raw) - 1 loop
    cells := v_raw->i; v_line := i + 2;
    data := '{}'; ben := '{}'; shown := '[]'; errs := '[]'; warns := '[]';

    for col in select * from jsonb_array_elements(v_mapping) loop
      raw := btrim(coalesce(cells->>((col->>'index')::int), ''));
      val := null; disp := raw;
      if raw <> '' then
        case col->>'type'
          when 'enum_type' then
            n := replace(public.csv_normalize(raw), ' ', '');
            val := case when n in ('video', 'distance', 'adistance') or n like 'visio%' then '"visio"'
                        when n like 'rdfs%' then '"rdfs"' when n like 'rdf%' then '"rdf"' end;
            if val is null then errs := errs || to_jsonb('Type de mandat inconnu : « ' || raw || ' » (attendu : Visio, RDF ou RDFS)');
            else disp := v_type_labels->>(val #>> '{}'); end if;
          when 'enum_priority' then
            n := public.csv_normalize(raw);
            val := case when n in ('basse', 'bas', 'faible', 'low', '1') then '"low"'
                        when n in ('moyenne', 'moyen', 'normale', 'normal', 'medium', '2') then '"medium"'
                        when n in ('haute', 'haut', 'elevee', 'eleve', 'high', 'importante', '3') then '"high"'
                        when n in ('critique', 'urgente', 'urgent', 'critical', 'tres urgent', '4') then '"critical"' end;
            if val is null then warns := warns || to_jsonb('Priorité inconnue ignorée : « ' || raw || ' »');
            else disp := v_prio_labels->>(val #>> '{}'); end if;
          when 'list' then
            select coalesce(jsonb_agg(x), '[]'::jsonb) into val from regexp_split_to_table(raw, '\s*[|;,]\s*') x where x <> '';
            select string_agg(x, ', ') into disp from jsonb_array_elements_text(val) x;
          when 'date' then
            n := public.csv_to_date(raw);
            if n is null then warns := warns || to_jsonb((col->>'label') || ' illisible ignorée : « ' || raw || ' »');
            else val := to_jsonb(n); disp := split_part(n, '-', 3) || '/' || split_part(n, '-', 2) || '/' || split_part(n, '-', 1); end if;
          when 'datetime' then
            ts := public.csv_to_datetime(raw);
            if ts is null then warns := warns || to_jsonb((col->>'label') || ' illisible ignoré : « ' || raw || ' »');
            else val := to_jsonb(to_char(ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
                 disp := to_char(ts at time zone 'Europe/Paris', 'DD/MM/YYYY HH24:MI'); end if;
          when 'bool' then
            n := public.csv_normalize(raw);
            if n in ('oui', 'o', 'yes', 'y', 'true', 'vrai', '1', 'x', 'actif', 'active') then val := 'true'; disp := 'Oui';
            elsif n in ('non', 'n', 'no', 'false', 'faux', '0', 'inactif') then val := 'false'; disp := 'Non';
            else warns := warns || to_jsonb((col->>'label') || ' : « ' || raw || ' » n''est ni oui ni non, ignoré'); end if;
          when 'phone' then
            n := regexp_replace(raw, '[^\d+]', '', 'g');
            if n ~ '^\d{9}$' then n := '0' || n; end if; -- Excel a supprimé le 0 initial
            if n <> '' then val := to_jsonb(n); disp := n; end if;
          else
            val := to_jsonb(raw);
        end case;
      end if;
      if val is not null and val <> '[]'::jsonb then
        if (col->>'key') like 'beneficiary.%' then ben := ben || jsonb_build_object(substr(col->>'key', 13), val);
        else data := data || jsonb_build_object(col->>'key', val); end if;
      end if;
      shown := shown || jsonb_build_object('label', col->>'label', 'csv', col->>'csv',
                 'value', coalesce(nullif(disp, ''), '—'), 'empty', raw = '');
    end loop;

    -- Contrôles obligatoires (mêmes règles que le formulaire).
    if data->>'mandate_type' is null and not exists (select 1 from jsonb_array_elements_text(errs) e where e like 'Type de mandat%') then
      errs := errs || '"Type de mandat manquant"';
    end if;
    if data->>'address_line_1' is null then errs := errs || '"Adresse manquante"'; end if;
    if ben->>'last_name' is null then errs := errs || '"Nom du bénéficiaire manquant"'; end if;
    if ben->>'first_name' is null then errs := errs || '"Prénom du bénéficiaire manquant"'; end if;

    -- N° de dossier assureur : unique chez l'assureur et dans le fichier.
    if data->>'insurer_file_number' is not null then
      num := lower(btrim(data->>'insurer_file_number'));
      if num = any(v_existing) then
        errs := errs || to_jsonb('N° de dossier « ' || (data->>'insurer_file_number') || ' » déjà existant chez cet assureur');
      elsif v_seen_numbers ? num then
        errs := errs || to_jsonb('N° de dossier « ' || (data->>'insurer_file_number') || ' » déjà utilisé ligne ' || (v_seen_numbers->>num));
      else v_seen_numbers := v_seen_numbers || jsonb_build_object(num, v_line); end if;
    end if;

    -- Doublon dans le fichier (même bénéficiaire, même adresse).
    dupkey := public.csv_normalize(concat_ws(' ', ben->>'last_name', ben->>'first_name', data->>'address_line_1'));
    if dupkey <> '' and v_seen ? dupkey then warns := warns || to_jsonb('Doublon probable de la ligne ' || (v_seen->>dupkey));
    elsif dupkey <> '' then v_seen := v_seen || jsonb_build_object(dupkey, v_line); end if;

    v_rows := v_rows || jsonb_build_object(
      'line', v_line,
      'title', coalesce(nullif(concat_ws(' ', ben->>'last_name', ben->>'first_name'), ''), 'Bénéficiaire non renseigné'),
      'subtitle', concat_ws(', ', data->>'address_line_1', nullif(concat_ws(' ', data->>'postal_code', data->>'city'), '')),
      'data', data || jsonb_build_object('beneficiary', ben),
      'fields', shown, 'errors', errs, 'warnings', warns,
      'include', jsonb_array_length(errs) = 0,
      'status', case when jsonb_array_length(errs) > 0 then 'error' else 'ready' end,
      'message', '');
  end loop;

  return s || jsonb_build_object('mapping', v_mapping, 'ignored', v_ignored, 'missingRequired', v_missing, 'rows', v_rows);
end $$;

revoke all on function public.csv_import_analyze(text, text, text) from public, anon;
revoke all on function public.csv_import_build(jsonb) from public, anon;
grant execute on function public.csv_import_analyze(text, text, text) to authenticated;
grant execute on function public.csv_import_build(jsonb) to authenticated;
