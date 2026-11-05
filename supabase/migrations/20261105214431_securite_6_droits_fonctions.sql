-- PLOMI — Sécurité étape 6 : plus aucune fonction appelable sans connexion,
-- et les fonctions internes (déclencheurs, calculs) fermées aux comptes connectés.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f'
              and (p.prorettype = 'trigger'::regtype
                   or p.proname in ('expert_list_rule_members','rls_auto_enable','get_complete_schema')) loop
    execute format('revoke execute on function %s from authenticated', f.sig);
  end loop;
end $$;

alter default privileges in schema public revoke execute on functions from public, anon;
