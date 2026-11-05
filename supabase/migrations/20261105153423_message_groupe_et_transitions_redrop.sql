do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.transition_mandate_status(uuid,mandate_status,uuid,text,assignment_type,uuid[])'::regprocedure);
  n := d;
  n := replace(n, $r$when 'drop_pending'   then array['dropped','assigned','cancelled']$r$,
                  $r$when 'drop_pending'   then array['dropped','redrop','assigned','cancelled']$r$);
  n := replace(n, $r$when 'assigned'       then array['in_progress','drop_pending','suspended','cancelled']$r$,
                  $r$when 'assigned'       then array['in_progress','drop_pending','redrop','suspended','cancelled']$r$);
  n := replace(n, $r$when 'in_progress'    then array['waiting_report','suspended']$r$,
                  $r$when 'in_progress'    then array['waiting_report','redrop','suspended']$r$);
  n := replace(n, $r$    v_allowed := case v_current$r$,
                  $r$    -- Un mandat déjà diffusé une fois (drop_at renseigné) revient sur la carte en redrop
    if p_new_status = 'dropped' and v_current = 'drop_pending'
       and exists (select 1 from public.mandates where id = p_mandate_id and drop_at is not null) then
        p_new_status := 'redrop';
    end if;

    v_allowed := case v_current$r$);
  if n = d or (length(n) - length(d)) < 200 then
    raise exception 'motifs introuvables dans transition_mandate_status';
  end if;
  execute n;
end $mig$;

create or replace function public.manager_broadcast(
    p_type         text,
    p_audience     text,
    p_message      text,
    p_mandate_ids  uuid[]  default '{}',
    p_unassign     boolean default false,
    p_uncloud      boolean default false
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    v_id         uuid := gen_random_uuid();
    v_title      text;
    v_recipients int := 0;
    v_unassigned int := 0;
    v_uncloud    int := 0;
    v_m          record;
begin
    if auth.uid() is null then raise exception 'Utilisateur non connecté'; end if;
    if public.current_expert_id() is not null then
        raise exception 'Le message groupé est réservé aux gestionnaires';
    end if;

    v_title := case p_type
        when 'alerte'     then 'Alerte'
        when 'anomalie'   then 'Anomalie'
        when 'nouveautes' then 'Nouveautés'
    end;
    if v_title is null then raise exception 'Type de message invalide : %', p_type; end if;
    if p_audience not in ('connected','all') then raise exception 'Destinataires invalides : %', p_audience; end if;
    if nullif(trim(coalesce(p_message,'')), '') is null then raise exception 'Le message est obligatoire'; end if;
    if (p_unassign or p_uncloud) and cardinality(coalesce(p_mandate_ids,'{}')) = 0 then
        raise exception 'Cochez au moins un mandat pour retirer l''attribution ou sortir du cloud';
    end if;

    insert into public.notifications (user_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
    select e.user_id, 'message', v_title, trim(p_message), 'in_app', false, now(), 'broadcast', v_id, 'dashboard'
      from public.experts e
     where e.user_id is not null
       and (p_audience = 'all' or e.status_experts = 'connecte');
    get diagnostics v_recipients = row_count;

    if p_unassign then
        for v_m in
            select m.id, m.reference, e.user_id as expert_user
              from public.mandates m
              left join public.experts e on e.id = m.assigned_expert_id
             where m.id = any(p_mandate_ids) and m.status in ('assigned','in_progress')
        loop
            if v_m.expert_user is not null then
                insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
                values (v_m.expert_user, v_m.id, 'status_change', 'Attribution retirée',
                        'Le mandat ' || coalesce(v_m.reference,'') || ' vous a été retiré. ' || trim(p_message),
                        'in_app', false, now(), 'broadcast', v_id, 'mandate');
            end if;
            perform public.transition_mandate_status(v_m.id, 'redrop');
            v_unassigned := v_unassigned + 1;
        end loop;
    end if;

    if p_uncloud then
        for v_m in
            select m.id from public.mandates m
             where m.id = any(p_mandate_ids) and m.status in ('dropped','redrop')
        loop
            perform public.transition_mandate_status(v_m.id, 'drop_pending');
            v_uncloud := v_uncloud + 1;
        end loop;
    end if;

    insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
    values (auth.uid(), 'broadcast', v_id, 'group_message',
            jsonb_build_object('type', p_type, 'audience', p_audience, 'message', trim(p_message),
                               'recipients', v_recipients, 'mandate_ids', p_mandate_ids,
                               'unassign', p_unassign, 'unassigned', v_unassigned,
                               'uncloud', p_uncloud, 'uncloud_count', v_uncloud));

    return jsonb_build_object('broadcast_id', v_id, 'recipients', v_recipients,
                              'unassigned', v_unassigned, 'uncloud', v_uncloud);
end;
$function$;

grant execute on function public.manager_broadcast(text, text, text, uuid[], boolean, boolean) to authenticated;
