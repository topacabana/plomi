-- PLOMI — Relance des tests 01 à 18 (cloisonnement gestionnaires) après le nettoyage des comptes à double rôle.
-- À exécuter sur la base de production en super-utilisateur. Aucune donnée n'est modifiée :
-- les tests qui écrivent le font dans un bloc annulé (exception volontaire 'ROLLBACK_TEST').
-- Comptes : gestionnaire A = cadelisthomas7 (org Assurances Solidaires Mutuelle),
--           gestionnaire B = antoine.moreau (org Covéa Garanties Habitat).

drop table if exists pg_temp.resultats;
create temp table resultats (num text, test text, attendu text, obtenu text, ok boolean);


do $$
declare
  A  uuid := '51bd0c83-94f1-4274-b3e3-16fd853d5616';  orgA uuid := '00000001-0000-4000-8000-000000000001';
  B  uuid := '00000002-0000-4000-8000-000000000004';  orgB uuid := '00000001-0000-4000-8000-000000000002';
  ids uuid[]; n int; msg text; ex uuid; ben uuid; res jsonb;
begin
  -- 01 / 02 : mandats
  perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
  select array_agg(id) into ids from public.mandates;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  select count(*) into n from public.mandates where id = any(ids) and insurance_org_id <> orgA;
  insert into resultats values ('01','Gest. A ne voit aucun mandat d''une autre organisation','0',n,n=0);
  select count(*) into n from public.mandates where id = any(ids) and insurance_org_id = orgA;
  insert into resultats values ('02','Gest. A voit les mandats de son organisation','> 0',n,n>0);

  -- 03 : bénéficiaires
  perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
  select array_agg(id) into ids from public.beneficiaries;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  select count(*) into n from public.beneficiaries where id = any(ids) and organization_id is distinct from orgA;
  insert into resultats values ('03','Gest. A ne voit aucun bénéficiaire d''une autre organisation','0',n,n=0);

  -- 04 : rapports
  perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
  select array_agg(id) into ids from public.rdf_reports;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  select count(*) into n from public.rdf_reports r join public.mandates m on m.id = r.mandate_id
   where r.id = any(ids) and m.insurance_org_id <> orgA;
  insert into resultats values ('04','Gest. A ne voit aucun rapport d''une autre organisation','0',n,n=0);

  -- 05 : profils
  perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
  select count(*) into n from public.user_profiles up
   where up.id <> A and coalesce(up.organization_id::text,'') <> orgA::text;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  insert into resultats values ('05','Gest. A ne lit pas les profils des comptes hors de son organisation','0',n,n=0);

  -- 06 : annuaire = base d'experts de l'organisation
  perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
  select array_agg(id) into ids from public.experts;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  select count(*) into n from unnest(ids) x where not exists
    (select 1 from public.org_experts oe where oe.expert_id = x and oe.organization_id = orgA);
  insert into resultats values ('06','Gest. A ne voit que les experts de sa base', '0 hors base', n || ' hors base / ' || coalesce(array_length(ids,1),0) || ' visibles', n=0);

  -- 07 : notifications
  perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
  select count(*) into n from public.notifications where user_id <> A;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  insert into resultats values ('07','Gest. A ne voit pas les notifications des autres','0',n,n=0);

  -- 08 : save_mandate_form sans type
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
    perform public.save_mandate_form(null, '{"address_line_1":"1 rue du Test"}'::jsonb, false, null, false);
    msg := 'accepté';
    raise exception 'ROLLBACK_TEST';
  exception when others then
    if sqlerrm <> 'ROLLBACK_TEST' then msg := sqlerrm; end if;
  end;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  insert into resultats values ('08','save_mandate_form refuse un mandat sans type','refus',msg, msg ilike '%type%');

  -- 09 / 10 : brouillon créé dans l'organisation du gestionnaire, bénéficiaire forcé dans l'organisation
  select id into ben from public.beneficiaries where organization_id = orgA limit 1;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
    res := to_jsonb(public.save_mandate_form(null, jsonb_build_object('mandate_type','rdf','address_line_1','1 rue du Test',
             'postal_code','75001','city','Paris','beneficiary_id',ben,'requester_type','individual'), false, null, false));
    perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
    select count(*) into n from public.mandates m
      where m.id = coalesce((res->>'mandate_id')::uuid, (res->>'id')::uuid, (res#>>'{}')::uuid) and m.insurance_org_id = orgA and m.status::text = 'draft';
    msg := case when n = 1 then 'brouillon dans l''org A' else 'retour : ' || left(res::text, 120) end;
    raise exception 'ROLLBACK_TEST';
  exception when others then
    if sqlerrm <> 'ROLLBACK_TEST' then msg := 'erreur : ' || sqlerrm; end if;
  end;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  insert into resultats values ('09','save_mandate_form crée un brouillon dans l''org du gestionnaire','brouillon dans l''org A',msg, msg = 'brouillon dans l''org A');

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
    insert into public.beneficiaries (first_name, last_name, organization_id) values ('Test', 'Forçage', orgB) returning organization_id into ex;
    msg := case when ex = orgA then 'forcé dans l''org A' else 'org ' || ex end;
    raise exception 'ROLLBACK_TEST';
  exception when others then
    if sqlerrm <> 'ROLLBACK_TEST' then msg := 'refusé : ' || sqlerrm; end if;
  end;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  insert into resultats values ('10','Un bénéficiaire créé est forcé dans l''org du gestionnaire','forcé ou refusé',msg, msg like 'forcé%' or msg like 'refusé%');

  -- 11 / 12 / 13 : listes
  select oe.expert_id into ex from public.org_experts oe join public.experts e on e.id = oe.expert_id
   where oe.organization_id = orgA and coalesce(e.status_experts::text,'') <> 'suspendu'
     and not exists (select 1 from public.expert_list_members m where m.expert_id = e.id and m.list_id = 'cadb8448-51bd-416b-9aa1-2e721da35910') limit 1;
  for n in 11..13 loop
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
      perform public.add_experts_to_lists(array[ex], array[case n when 11 then '21000000-0000-4000-8000-000000000001'
                                                               when 12 then 'cadb8448-51bd-416b-9aa1-2e721da35910'
                                                               else '22000000-0000-4000-8000-000000000006' end::uuid]);
      msg := 'accepté';
      raise exception 'ROLLBACK_TEST';
    exception when others then
      if sqlerrm <> 'ROLLBACK_TEST' then msg := 'refusé : ' || sqlerrm; end if;
    end;
    perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
    insert into resultats values (n::text,
      case n when 11 then 'Ajout manuel refusé sur une liste automatique'
             when 12 then 'Ajout manuel accepté sur une liste manuelle de son org'
             else 'Ajout refusé sur une liste d''une autre organisation' end,
      case n when 12 then 'accepté' else 'refus' end, msg,
      case n when 12 then msg = 'accepté' else msg like 'refusé%' end);
  end loop;

  -- 15 : create_expert_record fermée
  insert into resultats values ('15','create_expert_record inaccessible depuis l''app','non exécutable',
    case when has_function_privilege('authenticated','public.create_expert_record(uuid,uuid,jsonb)','execute') then 'exécutable' else 'non exécutable' end,
    not has_function_privilege('authenticated','public.create_expert_record(uuid,uuid,jsonb)','execute'));

  -- 16 : pas de modification directe des fiches experts
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', A, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
    update public.experts set updated_at = updated_at;
    get diagnostics n = row_count;
    msg := n::text;
    raise exception 'ROLLBACK_TEST';
  exception when others then
    if sqlerrm <> 'ROLLBACK_TEST' then msg := '0 (refusé)'; end if;
  end;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  insert into resultats values ('16','Le gestionnaire ne modifie pas les fiches experts en direct','0',msg, msg in ('0','0 (refusé)'));

  -- 17 / 18 : gestionnaire B
  perform set_config('request.jwt.claims', json_build_object('sub', B, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
  select count(*) into n from public.mandates where insurance_org_id = orgA;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  insert into resultats values ('17','Gest. B ne voit aucun mandat de l''org A','0',n,n=0);
  perform set_config('request.jwt.claims', json_build_object('sub', B, 'role', 'authenticated')::text, true), set_config('role', 'authenticated', true);
  select count(*) into n from public.expert_lists where organization_id = orgA;
  perform set_config('role', 'none', true), set_config('request.jwt.claims', '', true);
  insert into resultats values ('18','Gest. B ne voit pas les listes de l''org A','0',n,n=0);
end $$;

select num, test, attendu, obtenu, case when ok then 'OK' else 'ÉCART' end as resultat from resultats order by num;
