create or replace function public.current_expert_id()
 returns uuid language sql stable security definer set search_path to 'public'
as $$ select id from public.experts where user_id = auth.uid() limit 1 $$;
grant execute on function public.current_expert_id() to authenticated;

create or replace view public.my_active_mandates
with (security_invoker = true) as
select m.*
from public.mandates m
where m.assigned_expert_id = public.current_expert_id()
  and m.status in ('assigned','in_progress');
grant select on public.my_active_mandates to authenticated;

create or replace function public.expert_start_mandate(p_mandate_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype;
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then
        raise exception 'Ce mandat ne vous est pas attribué';
    end if;
    if v_m.status <> 'assigned' then
        raise exception 'Le rapport ne peut être démarré que pour un mandat attribué (statut actuel : %)', v_m.status;
    end if;
    perform public.transition_mandate_status(p_mandate_id, 'in_progress');
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id)
    values (v_expert, 'intervention_started', p_mandate_id);
end;
$function$;
grant execute on function public.expert_start_mandate(uuid) to authenticated;

create or replace function public.expert_submit_report(p_mandate_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v_report uuid;
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then
        raise exception 'Ce mandat ne vous est pas attribué';
    end if;
    if v_m.status <> 'in_progress' then
        raise exception 'Le rapport ne peut être envoyé que pour un mandat en cours (statut actuel : %)', v_m.status;
    end if;
    select id into v_report from public.rdf_reports
     where mandate_id = p_mandate_id and created_by = auth.uid() and coalesce(status,'draft') = 'draft'
     order by created_at desc limit 1;
    if v_report is null then raise exception 'Aucun rapport enregistré pour ce mandat'; end if;

    update public.rdf_reports set status = 'submitted', submitted_at = now() where id = v_report;
    perform public.transition_mandate_status(p_mandate_id, 'waiting_report');
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
    values (v_expert, 'report_submitted', p_mandate_id, jsonb_build_object('report_id', v_report));
end;
$function$;
grant execute on function public.expert_submit_report(uuid) to authenticated;

create or replace function public.expert_abandon_mandate(p_mandate_id uuid, p_motif text)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype;
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    if nullif(trim(coalesce(p_motif,'')), '') is null then raise exception 'Le motif d''abandon est obligatoire'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then
        raise exception 'Ce mandat ne vous est pas attribué';
    end if;
    if v_m.status not in ('assigned','in_progress') then
        raise exception 'Ce mandat ne peut plus être abandonné (statut actuel : %)', v_m.status;
    end if;
    perform public.transition_mandate_status(p_mandate_id, 'suspended', null, 'Abandon expert : ' || trim(p_motif));
    update public.mandate_assignments set status = 'refused', refused_at = now(), comment = trim(p_motif)
     where mandate_id = p_mandate_id and expert_id = v_expert and status in ('pending','accepted');
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
    values (v_expert, 'mandate_refused', p_mandate_id, jsonb_build_object('motif', trim(p_motif), 'from_status', v_m.status)),
           (v_expert, 'redrop_caused',  p_mandate_id, jsonb_build_object('reason', 'abandon'));
end;
$function$;
grant execute on function public.expert_abandon_mandate(uuid, text) to authenticated;

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.expert_claim_mandate(uuid,timestamptz)'::regprocedure);
  n := replace(d,
    $r$    select * into v_m from public.mandates where id = p_mandate_id for update;$r$,
    $r$    if exists (select 1 from public.mandates
               where assigned_expert_id = v_expert_id and status in ('assigned','in_progress')) then
        raise exception 'Vous avez déjà un mandat à traiter : terminez-le avant d''en prendre un autre';
    end if;

    select * into v_m from public.mandates where id = p_mandate_id for update;$r$);
  if n = d then raise exception 'motif introuvable dans expert_claim_mandate'; end if;
  execute n;
end $mig$;
