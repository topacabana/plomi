-- RDFS : pas de rapport (envoi ni soumission) sans accord du bénéficiaire pour investigations destructives.
do $do$
declare
  f text;
  v_def text;
  v_anchor text := E'(statut actuel : %)'', v_m.status;\n    end if;\n';
  v_guard text := E'\n    if v_m.mandate_type::text = ''rdfs'' and not exists (select 1 from public.destructive_consents dc where dc.mandate_id = p_mandate_id) then\n        raise exception ''RDFS : l''''accord du bénéficiaire pour les investigations destructives doit être enregistré avant le rapport'';\n    end if;\n';
begin
  foreach f in array array['public.expert_send_report(uuid, text, jsonb, text[], text)', 'public.expert_submit_report(uuid)'] loop
    v_def := pg_get_functiondef(f::regprocedure);
    if position('destructive_consents' in v_def) = 0 then
      if position(v_anchor in v_def) = 0 then
        raise exception 'Ancre introuvable dans %', f;
      end if;
      execute replace(v_def, v_anchor, v_anchor || v_guard);
    end if;
  end loop;
end;
$do$;
