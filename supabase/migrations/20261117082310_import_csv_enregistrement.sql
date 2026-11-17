-- Import CSV : enregistrement groupé des lignes côté serveur (remplace la boucle JavaScript du bouton « Importer les mandats »).
-- Une ligne en erreur n'arrête pas les suivantes (sous-transaction par ligne).
-- Les mandats importés sont des demandes de l'assureur choisi (organisme demandeur obligatoire).

create or replace function public.csv_import_commit(p_state jsonb)
returns jsonb
language plpgsql
security invoker
set search_path to 'public'
as $$
declare
  s jsonb := coalesce(p_state, '{}'::jsonb);
  v_insurer uuid := nullif(s->>'insurerId', '')::uuid;
  v_import uuid := nullif(s->>'importId', '')::uuid;
  v_rows jsonb := coalesce(s->'rows', '[]'::jsonb);
  v_out jsonb := '[]'::jsonb;
  r jsonb;
  v_id uuid;
  v_imported int := 0;
  v_failed int := 0;
  v_msg text;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if v_insurer is null then raise exception 'Choisissez l''assureur de l''import'; end if;

  -- Trace de l'import (une seule fois, réutilisée si on relance les lignes en échec).
  if v_import is null then
    v_import := public.mandate_import_start(v_insurer, coalesce(s->>'fileName', 'import.csv'), jsonb_array_length(v_rows));
  end if;

  for r in select * from jsonb_array_elements(v_rows) loop
    if coalesce((r->>'include')::boolean, false) and r->>'status' in ('ready', 'failed') then
      begin
        v_id := public.save_mandate_form(
          null,
          coalesce(r->'data', '{}'::jsonb) || jsonb_build_object('insurer_id', v_insurer, 'import_id', v_import, 'requester_type', 'insurer'),
          false, null, true);  -- le mandat arrive dans la Liste de drop
        v_imported := v_imported + 1;
        r := r || jsonb_build_object('status', 'imported', 'include', false, 'mandateId', v_id, 'message', 'Importé dans la Liste de drop');
      exception when others then
        v_msg := case when sqlerrm ~* 'mandates_insurer_file_number_uidx|duplicate key'
                      then 'ce n° de dossier existe déjà chez cet assureur' else sqlerrm end;
        r := r || jsonb_build_object('status', 'failed', 'message', 'Échec : ' || v_msg);
      end;
    end if;
    v_out := v_out || jsonb_build_array(r);
  end loop;

  select count(*) into v_failed from jsonb_array_elements(v_out) x where x->>'status' in ('error', 'failed');
  perform public.mandate_import_finish(v_import, v_imported, v_failed);

  return s || jsonb_build_object('rows', v_out, 'importId', v_import, 'importing', false, 'done', true, 'error', '');
end $$;

revoke all on function public.csv_import_commit(jsonb) from public, anon;
grant execute on function public.csv_import_commit(jsonb) to authenticated;

-- Rattrapage : la séquence des références de mandat (MAN-0001…) existe en production
-- mais manquait dans l'instantané du schéma rejoué par la CI. Sans effet en production.
create sequence if not exists public.mandate_reference_seq;
