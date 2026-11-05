-- Règle validée 05/11/2026 : chaque redrop passe le mandat en priorité 'critical'
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.transition_mandate_status(uuid,mandate_status,uuid,text,assignment_type,uuid[])'::regprocedure);
  n := replace(d,
    $r$        status = p_new_status,$r$,
    $r$        status = p_new_status,
        priority = case when p_new_status = 'redrop' then 'critical'::priority_level else priority end,$r$);
  if n = d then raise exception 'motif introuvable'; end if;
  execute n;
end $mig$;
