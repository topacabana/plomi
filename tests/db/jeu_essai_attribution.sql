-- PLOMI — Jeu d'essai de l'attribution manuelle par lot (manual_assign_mandates)
-- Version 2 (18/11/2026) : lot de 7 couples, après correction des écarts 1 et 2 et ajout de la règle CGU (16/11).
-- Exécution : éditeur SQL ou psql, en super-utilisateur. Tout est annulé (exception volontaire ROLLBACK_TEST) ;
-- le résultat est lu dans la table temporaire « je ».

drop table if exists pg_temp.je;
create temp table je (res jsonb);

do $$
declare r jsonb; after jsonb; cnt_assign int; logrow jsonb; e7 text; e8 text; out jsonb;
begin
  begin
    -- Identité simulée : gestionnaire de l'organisation Assurances Solidaires Mutuelle
    perform set_config('request.jwt.claims', json_build_object('sub','51bd0c83-94f1-4274-b3e3-16fd853d5616','role','authenticated')::text, true);
    perform set_config('role','authenticated',true);

    -- E1 à E6 + E9 dans un seul lot
    r := public.manual_assign_mandates('[
      {"mandate_id":"00000006-0000-4000-8000-000000000013","expert_id":"00000004-0000-4000-8000-000000000001"},
      {"mandate_id":"00000006-0000-4000-8000-000000000007","expert_id":"35152001-fbc1-492e-b592-b42e9d19d81d"},
      {"mandate_id":"00000006-0000-4000-8000-000000000008","expert_id":"00000004-0000-4000-8000-000000000006"},
      {"mandate_id":"00000006-0000-4000-8000-000000000008","expert_id":"00000004-0000-4000-8000-000000000004"},
      {"mandate_id":"00000006-0000-4000-8000-000000000018","expert_id":"00000004-0000-4000-8000-000000000001"},
      {"mandate_id":"00000006-0000-4000-8000-000000000019","expert_id":"00000004-0000-4000-8000-000000000001"},
      {"mandate_id":"baca0d7a-ac44-4ea0-aadb-cebd07986ec8","expert_id":"00000004-0000-4000-8000-000000000002"}
    ]'::jsonb);
    perform set_config('role','none',true);

    -- État des mandats après l'appel
    select jsonb_agg(jsonb_build_object('ref',m.reference,'status',m.status,'expert',public.expert_display_name(m.assigned_expert_id)) order by m.reference)
      into after from mandates m
     where m.id in ('00000006-0000-4000-8000-000000000013','00000006-0000-4000-8000-000000000007','00000006-0000-4000-8000-000000000008',
                    '00000006-0000-4000-8000-000000000018','00000006-0000-4000-8000-000000000019','baca0d7a-ac44-4ea0-aadb-cebd07986ec8');
    select count(*) into cnt_assign from mandate_assignments
     where mandate_id in ('00000006-0000-4000-8000-000000000013','00000006-0000-4000-8000-000000000007')
       and status='pending' and assignment_type='manual' and assigned_at > now() - interval '1 minute';
    select new_values_json - 'errors' into logrow from activity_logs where action='manual_assignment' order by created_at desc limit 1;

    -- E7 : appel par un compte expert
    begin
      perform set_config('request.jwt.claims', json_build_object('sub',(select user_id from experts where id='00000004-0000-4000-8000-000000000002'),'role','authenticated')::text, true);
      perform set_config('role','authenticated',true);
      perform public.manual_assign_mandates('[{"mandate_id":"00000006-0000-4000-8000-000000000008","expert_id":"00000004-0000-4000-8000-000000000002"}]');
      e7 := 'ACCEPTÉ (anomalie)';
    exception when others then e7 := sqlerrm; end;
    perform set_config('role','none',true);

    -- E8 : lot vide
    begin
      perform set_config('request.jwt.claims', json_build_object('sub','51bd0c83-94f1-4274-b3e3-16fd853d5616','role','authenticated')::text, true);
      perform set_config('role','authenticated',true);
      perform public.manual_assign_mandates('[]');
      e8 := 'ACCEPTÉ (anomalie)';
    exception when others then e8 := sqlerrm; end;
    perform set_config('role','none',true);

    out := jsonb_build_object('retour_fonction', r, 'etat_apres', after, 'affectations_creees', cnt_assign,
                              'journal', logrow, 'E7_expert', e7, 'E8_vide', e8);
    raise exception 'ROLLBACK_TEST';
  exception when others then
    if sqlerrm <> 'ROLLBACK_TEST' then out := jsonb_build_object('erreur', sqlerrm); end if;
  end;
  perform set_config('role','none',true);
  insert into je values (out);
end $$;

select jsonb_pretty(res) from je;
