do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.manager_broadcast(text,text,text,uuid[],boolean,boolean)'::regprocedure);
  n := replace(d,
    $r$    if public.current_expert_id() is not null then$r$,
    $r$    if not exists (select 1 from public.user_profiles where id = auth.uid() and role::text = 'gestionnaire_assurance') then$r$);
  if n = d then raise exception 'motif introuvable'; end if;
  execute n;
end $mig$;
