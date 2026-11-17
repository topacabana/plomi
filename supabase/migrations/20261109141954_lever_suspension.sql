-- PLOMI — Lever une suspension : le mandat reprend l'état qu'il avait avant d'être suspendu.
--   assigned / in_progress (expert toujours rattaché) -> assigned, même expert, même type d'attribution
--   dropped / redrop                                  -> même statut, mêmes listes ciblées
--   sinon (liste de drop, inconnu)                    -> drop_pending
-- Le statut d'origine est lu dans activity_logs (journal de transition_mandate_status).

-- Autoriser suspended -> dropped (reprise d'un mandat suspendu depuis la carte)
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.transition_mandate_status(uuid, mandate_status, uuid, text, assignment_type, uuid[])'::regprocedure);
  if position('when ''suspended''      then array[''redrop'',''assigned'',''drop_pending'',''cancelled'',''closed'']' in d) = 0 then
    raise exception 'transition_mandate_status : ligne suspended introuvable';
  end if;
  d := replace(d, 'when ''suspended''      then array[''redrop'',''assigned'',''drop_pending'',''cancelled'',''closed'']',
                  'when ''suspended''      then array[''dropped'',''redrop'',''assigned'',''drop_pending'',''cancelled'',''closed'']');
  execute d;
end $mig$;

create or replace function public.resume_mandate(p_mandate_id uuid, p_new_status text default null, p_motif text default null)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare
  v_status  mandate_status;
  v_expert  uuid;
  v_lists   uuid[];
  v_prev    text;
  v_type    assignment_type;
  v_target  mandate_status;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;

  select status, assigned_expert_id, target_list_ids into v_status, v_expert, v_lists
    from public.mandates where id = p_mandate_id;
  if not found then raise exception 'Mandat introuvable'; end if;
  if v_status <> 'suspended' then
    raise exception 'Le mandat % n''est pas suspendu', (select reference from public.mandates where id = p_mandate_id);
  end if;

  select old_values_json->>'status' into v_prev
    from public.activity_logs
   where entity_type = 'mandate' and entity_id = p_mandate_id and action = 'status_transition'
     and new_values_json->>'status' = 'suspended'
   order by created_at desc limit 1;

  if v_prev in ('assigned','in_progress') and v_expert is not null then
    select assignment_type into v_type from public.mandate_assignments
     where mandate_id = p_mandate_id and expert_id = v_expert order by assigned_at desc limit 1;
    perform public.transition_mandate_status(p_mandate_id, 'assigned', v_expert,
              coalesce(nullif(p_motif, ''), 'Suspension levée'), coalesce(v_type, 'manual'));
    v_target := 'assigned';
  elsif v_prev in ('dropped','redrop') then
    v_target := v_prev::mandate_status;
    perform public.transition_mandate_status(p_mandate_id, v_target, null,
              coalesce(nullif(p_motif, ''), 'Suspension levée'), 'manual', nullif(v_lists, '{}'));
  else
    v_target := 'drop_pending';
    perform public.transition_mandate_status(p_mandate_id, v_target, null, coalesce(nullif(p_motif, ''), 'Suspension levée'));
  end if;

  return v_target::text;
end $$;

revoke execute on function public.resume_mandate(uuid, text, text) from public, anon;
grant execute on function public.resume_mandate(uuid, text, text) to authenticated;
