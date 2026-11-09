-- PLOMI — Jeu d'essai de l'attribution manuelle par lot (manual_assign_mandates)
-- Exécution : dans l'éditeur SQL ou psql. Tout est annulé à la fin (RAISE EXCEPTION) :
-- le message d'erreur final contient le résultat du test au format JSON.
do $$
declare r jsonb; after jsonb; cnt_assign int; logrow jsonb; e7 text; e8 text;
begin
  -- Identité simulée : gestionnaire de l'organisation Assurances Solidaires Mutuelle
  perform set_config('request.jwt.claims', json_build_object('sub','51bd0c83-94f1-4274-b3e3-16fd853d5616','role','authenticated')::text, true);
  set local role authenticated;

  -- E1 à E6 dans un seul lot
  r := public.manual_assign_mandates('[
    {"mandate_id":"00000006-0000-4000-8000-000000000005","expert_id":"00000004-0000-4000-8000-000000000001"},
    {"mandate_id":"00000006-0000-4000-8000-000000000007","expert_id":"00000004-0000-4000-8000-000000000002"},
    {"mandate_id":"00000006-0000-4000-8000-000000000008","expert_id":"00000004-0000-4000-8000-000000000006"},
    {"mandate_id":"00000006-0000-4000-8000-000000000008","expert_id":"00000004-0000-4000-8000-000000000004"},
    {"mandate_id":"00000006-0000-4000-8000-000000000018","expert_id":"00000004-0000-4000-8000-000000000001"},
    {"mandate_id":"00000006-0000-4000-8000-000000000019","expert_id":"00000004-0000-4000-8000-000000000002"}
  ]'::jsonb);
  reset role;

  -- État des mandats après l'appel
  select jsonb_agg(jsonb_build_object('ref',m.reference,'status',m.status,'expert',e.last_name,'assigned_at_set',m.assigned_at is not null) order by m.reference)
    into after from mandates m left join experts e on e.id=m.assigned_expert_id
   where m.id in ('00000006-0000-4000-8000-000000000005','00000006-0000-4000-8000-000000000007','00000006-0000-4000-8000-000000000008','00000006-0000-4000-8000-000000000018','00000006-0000-4000-8000-000000000019');
  select count(*) into cnt_assign from mandate_assignments
   where mandate_id in ('00000006-0000-4000-8000-000000000005','00000006-0000-4000-8000-000000000007')
     and status='pending' and assignment_type='manual' and assigned_at > now() - interval '1 minute';
  select to_jsonb(x) into logrow from (select action, new_values_json from activity_logs where action='manual_assignment' order by created_at desc limit 1) x;

  -- E7 : appel par un compte expert
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',(select user_id from experts where id='00000004-0000-4000-8000-000000000002'),'role','authenticated')::text, true);
    set local role authenticated;
    perform public.manual_assign_mandates('[{"mandate_id":"00000006-0000-4000-8000-000000000008","expert_id":"00000004-0000-4000-8000-000000000002"}]');
    e7 := 'ACCEPTÉ (anomalie)';
  exception when others then e7 := sqlerrm; end;
  reset role;

  -- E8 : lot vide
  begin
    perform set_config('request.jwt.claims', json_build_object('sub','51bd0c83-94f1-4274-b3e3-16fd853d5616','role','authenticated')::text, true);
    set local role authenticated;
    perform public.manual_assign_mandates('[]');
    e8 := 'ACCEPTÉ (anomalie)';
  exception when others then e8 := sqlerrm; end;
  reset role;

  raise exception 'RESULTAT %', jsonb_pretty(jsonb_build_object('retour_fonction', r, 'etat_apres', after,
    'affectations_creees', cnt_assign, 'journal', logrow, 'E7_expert', e7, 'E8_vide', e8));
end $$;
