-- RGPD A4 — aucune RPC métier n'est appelable sans connexion.
-- is_supervisor() reste exécutable par anon : utilisée dans des politiques RLS, elle renvoie false.
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prosecdef
       and p.prorettype <> 'trigger'::regtype
       and p.proname not in ('is_supervisor', 'is_manager', 'current_user_organization_id')
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- expert_display_name : le revoke suffit (elle est aussi appelée par des triggers et des tâches cron,
-- une garde sur auth.role() les casserait).
