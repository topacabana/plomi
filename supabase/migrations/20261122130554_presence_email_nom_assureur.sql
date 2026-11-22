-- Emails de vérification de présence : ajoute le nom de l'assureur client (ou du donneur d'ordre)
-- dans le JSON renvoyé à l'edge function presence-verification
-- (« missionné par <structure de gestion> pour le compte de <assureur> »).
do $$
declare f text; d text;
begin
  foreach f in array array['presence_code_issue(uuid,uuid)', 'presence_code_check(uuid,uuid,text)'] loop
    d := pg_get_functiondef(('public.' || f)::regprocedure);
    d := replace(d,
      $r$'organization', (select name from public.organizations where id = v_m.insurance_org_id),$r$,
      $r$'organization', (select name from public.organizations where id = v_m.insurance_org_id),
    'insurer', coalesce((select name from public.insurers where id = v_m.insurer_id), nullif(v_m.requester_company_name, '')),$r$);
    if position('''insurer''' in d) = 0 then raise exception 'Remplacement impossible dans %', f; end if;
    execute d;
  end loop;
end $$;
