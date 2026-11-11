-- Un gestionnaire n'a pas de account_status (contrainte chk_expert_status_logic) :
-- le retrait passe uniquement par removed_at + le blocage de connexion côté Auth.
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.supervisor_remove_manager(uuid)'::regprocedure);
  n := regexp_replace(d, 'account_status\s*=\s*''banned''\s*,\s*', '');
  if n <> d then execute n; end if;
end $$;
