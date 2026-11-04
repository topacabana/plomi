do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.transition_mandate_status(uuid,mandate_status,uuid,text,assignment_type,uuid[])'::regprocedure);
  n := replace(d, $r$when p_new_status in ('drop_pending','assigned','cancelled') then '{}'$r$,
                  $r$when p_new_status in ('drop_pending','cancelled') then '{}'$r$);
  if n = d then raise exception 'motif introuvable'; end if;
  execute n;
end $mig$;
