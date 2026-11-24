-- Import CSV : prévenir dans l'aperçu qu'une ligne sans ses 3 créneaux sera importée « incomplète »
-- (inactive : ni diffusion ni attribution tant que le client ou le gestionnaire ne l'a pas complétée).
do $do$
declare v_def text := pg_get_functiondef('public.csv_import_build'::regproc);
        v_old text := '    if dupkey <> '''' and v_seen ? dupkey then';
        v_new text := '    if not (data ? ''slot_1_at'' and data ? ''slot_2_at'' and data ? ''slot_3_at'') then'
          || E'\n      warns := warns || to_jsonb(''Créneaux manquants : le mandat sera importé incomplet (inactif). Demandez-les au client depuis la fiche mandat.''::text);'
          || E'\n    end if;'
          || E'\n' || v_old;
begin
  if position(v_old in v_def) = 0 then raise exception 'csv_import_build : point d''insertion introuvable'; end if;
  if position('Créneaux manquants' in v_def) > 0 then return; end if;
  execute replace(v_def, v_old, v_new);
end $do$;
