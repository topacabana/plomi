-- C7 : un expert ne peut recevoir un mandat (attribution manuelle, réattribution,
-- prise de mandat) que s'il a accepté la version en vigueur des CGU.
-- Contrôle centralisé dans transition_mandate_status ; manual_assignment_data
-- expose cgu_ok pour l'affichage côté mandataire.

do $mig$
declare v_def text;
begin
  select pg_get_functiondef('public.transition_mandate_status(uuid, mandate_status, uuid, text, assignment_type, uuid[])'::regprocedure) into v_def;
  if position('CGU en vigueur' in v_def) = 0 then
    v_def := replace(v_def,
      $a$    if p_new_status = 'assigned' and p_expert_id is null then$a$,
      $b$    if p_new_status = 'assigned' and p_expert_id is not null
       and exists (select 1 from public.cgu_versions where is_current)
       and exists (select 1 from public.experts e
                    where e.id = p_expert_id
                      and e.cgu_version is distinct from (select version from public.cgu_versions where is_current)) then
        raise exception 'Expert n''ayant pas accepté les CGU en vigueur : attribution impossible tant qu''il ne les a pas acceptées à sa connexion';
    end if;

    if p_new_status = 'assigned' and p_expert_id is null then$b$);
    execute v_def;
  end if;

  select pg_get_functiondef('public.manual_assignment_data(uuid[])'::regprocedure) into v_def;
  if position('cgu_ok' in v_def) = 0 then
    v_def := replace(v_def,
      $a$'status', e.status_experts,$a$,
      $b$'status', e.status_experts,
               'cgu_ok', not exists (select 1 from public.cgu_versions cv where cv.is_current and e.cgu_version is distinct from cv.version),$b$);
    execute v_def;
  end if;
end
$mig$;
