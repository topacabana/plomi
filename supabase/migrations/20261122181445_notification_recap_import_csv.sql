-- Pendant un import CSV, pas une notification par mandat : un récapitulatif unique,
-- envoyé à tous les gestionnaires de l'organisation, y compris celui qui a importé.
create or replace function public.trg_notify_mandate_created()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
begin
  if coalesce(current_setting('plomi.bulk_import', true), '') = 'on' then
    return new;  -- import CSV : récapitulatif envoyé à la fin par csv_import_commit
  end if;
  perform public.notify_managers(new.insurance_org_id, 'status_change',
            coalesce(new.reference, 'Nouveau mandat') || ' créé',
            'Créé par ' || coalesce(public.lock_holder_name(coalesce(new.created_by_user_id, auth.uid())), 'import automatique')
              || coalesce(' — ' || new.city, '') || coalesce(' · ' || upper(new.mandate_type::text), '') || '.',
            new.id, 'mandate', new.id, 'mandate_details', coalesce(new.created_by_user_id, auth.uid()));
  return new;
end $function$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.csv_import_commit(jsonb)'::regprocedure);
  d := replace(d,
    $r$  for r in select * from jsonb_array_elements(v_rows) loop$r$,
    $r$  perform set_config('plomi.bulk_import', 'on', true);
  for r in select * from jsonb_array_elements(v_rows) loop$r$);
  d := replace(d,
    $r$  perform public.mandate_import_finish(v_import, v_imported, v_failed);$r$,
    $r$  perform set_config('plomi.bulk_import', 'off', true);
  perform public.mandate_import_finish(v_import, v_imported, v_failed);
  if v_imported > 0 or v_failed > 0 then
    perform public.notify_managers(public.current_user_organization_id(), 'system',
      'Import CSV : ' || v_imported || ' mandat' || case when v_imported > 1 then 's' else '' end || ' importé' || case when v_imported > 1 then 's' else '' end,
      coalesce((select name from public.insurers where id = v_insurer), 'Assureur') || ' · '
        || coalesce((select file_name from public.mandate_imports where id = v_import), 'fichier CSV')
        || ' · par ' || coalesce(public.lock_holder_name(auth.uid()), 'un gestionnaire')
        || case when v_failed > 0 then ' · ' || v_failed || ' ligne(s) en échec' else '' end
        || '. À diffuser depuis la Liste de drop.',
      null, 'import', v_import, 'drop_pending', null);
  end if;$r$);
  if position('plomi.bulk_import' in d) = 0 or position('Import CSV :' in d) = 0 then
    raise exception 'Remplacement impossible dans csv_import_commit';
  end if;
  execute d;
end $$;
