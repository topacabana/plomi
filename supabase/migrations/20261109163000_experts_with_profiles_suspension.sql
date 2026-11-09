-- Expose la date et le motif de suspension dans la vue de la fiche expert
do $mig$
declare d text; a text := 'END AS base_status
   FROM';
begin
  d := pg_get_viewdef('public.experts_with_profiles'::regclass);
  if position(a in d) = 0 then raise exception 'ancre introuvable'; end if;
  d := replace(d, a, 'END AS base_status,
    e.suspended_at,
    e.suspension_reason
   FROM');
  execute 'create or replace view public.experts_with_profiles as ' || d;
end $mig$;
