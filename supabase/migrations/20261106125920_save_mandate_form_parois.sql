do $$ declare d text; begin
  d := pg_get_functiondef('public.save_mandate_form(uuid, jsonb, boolean, uuid[], boolean)'::regprocedure);
  d := replace(d, $r$'network_available','symptoms'];$r$, $r$'network_available','symptoms','affected_surfaces'];$r$);
  execute d;
end $$;
