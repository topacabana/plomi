-- Import CSV : champs obligatoires renforcés et revérifiés côté serveur à l'enregistrement.
-- Obligatoires : type, adresse, code postal OU ville, nom, prénom, téléphone OU e-mail du bénéficiaire.
-- csv_import_commit ne fait plus confiance à l'état envoyé par l'app (« status », « include ») :
-- chaque ligne est revalidée avant enregistrement ; une ligne incomplète reste en erreur.

create or replace function public.csv_import_row_errors(p_data jsonb)
 returns text[]
 language sql
 immutable
 set search_path to 'public'
as $function$
  select array_remove(array[
    case when coalesce(p_data->>'mandate_type', '') not in ('rdf', 'rdfs', 'visio') then 'Type de mandat manquant ou inconnu' end,
    case when nullif(btrim(coalesce(p_data->>'address_line_1', '')), '') is null then 'Adresse manquante' end,
    case when nullif(btrim(coalesce(p_data->>'postal_code', '')), '') is null
          and nullif(btrim(coalesce(p_data->>'city', '')), '') is null then 'Code postal ou ville manquant' end,
    case when nullif(btrim(coalesce(p_data#>>'{beneficiary,last_name}', '')), '') is null then 'Nom du bénéficiaire manquant' end,
    case when nullif(btrim(coalesce(p_data#>>'{beneficiary,first_name}', '')), '') is null then 'Prénom du bénéficiaire manquant' end,
    case when nullif(btrim(coalesce(p_data#>>'{beneficiary,mobile_phone}', '')), '') is null
          and nullif(btrim(coalesce(p_data#>>'{beneficiary,landline_phone}', '')), '') is null
          and nullif(btrim(coalesce(p_data#>>'{beneficiary,email}', '')), '') is null
         then 'Coordonnées du bénéficiaire manquantes (téléphone ou e-mail)' end
  ], null);
$function$;
comment on function public.csv_import_row_errors(jsonb) is 'Champs obligatoires d''une ligne d''import CSV (type, adresse, CP ou ville, nom, prénom, téléphone ou e-mail).';

do $d$
declare v text;
begin
  -- 1. Analyse : colonnes obligatoires et erreurs par ligne
  v := pg_get_functiondef('public.csv_import_build(jsonb)'::regprocedure);
  v := replace(v,
$a$  foreach k in array v_required loop$a$,
$a$  if not exists (select 1 from jsonb_array_elements(v_mapping) m where m->>'key' in ('postal_code', 'city')) then
    v_missing := v_missing || to_jsonb('Code postal ou ville'::text);
  end if;
  if not exists (select 1 from jsonb_array_elements(v_mapping) m where m->>'key' in ('beneficiary.mobile_phone', 'beneficiary.landline_phone', 'beneficiary.email')) then
    v_missing := v_missing || to_jsonb('Téléphone ou e-mail du bénéficiaire'::text);
  end if;
  foreach k in array v_required loop$a$);
  v := replace(v,
$a$    if ben->>'first_name' is null then errs := errs || '"Prénom du bénéficiaire manquant"'; end if;$a$,
$a$    if ben->>'first_name' is null then errs := errs || '"Prénom du bénéficiaire manquant"'; end if;
    if data->>'postal_code' is null and data->>'city' is null then errs := errs || '"Code postal ou ville manquant"'; end if;
    if ben->>'mobile_phone' is null and ben->>'landline_phone' is null and ben->>'email' is null then
      errs := errs || '"Coordonnées du bénéficiaire manquantes (téléphone ou e-mail)"';
    end if;$a$);
  if position('Coordonnées du bénéficiaire manquantes' in v) = 0 or position('Téléphone ou e-mail du bénéficiaire' in v) = 0 then
    raise exception 'csv_import_build : motif introuvable';
  end if;
  execute v;

  -- 2. Enregistrement : revalidation serveur de chaque ligne
  v := pg_get_functiondef('public.csv_import_commit(jsonb)'::regprocedure);
  v := replace(v,
$a$    if coalesce((r->>'include')::boolean, false) and r->>'status' in ('ready', 'failed') then
      begin$a$,
$a$    if coalesce((r->>'include')::boolean, false) and r->>'status' in ('ready', 'failed')
       and cardinality(public.csv_import_row_errors(r->'data')) > 0 then
      r := r || jsonb_build_object('status', 'error', 'include', false,
                 'errors', to_jsonb(public.csv_import_row_errors(r->'data')),
                 'message', 'Refusé : ' || array_to_string(public.csv_import_row_errors(r->'data'), ', '));
    elsif coalesce((r->>'include')::boolean, false) and r->>'status' in ('ready', 'failed') then
      begin$a$);
  if position('csv_import_row_errors' in v) = 0 then raise exception 'csv_import_commit : motif introuvable'; end if;
  execute v;
end $d$;
