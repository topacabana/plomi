alter table public.rdf_reports
  add column if not exists hypotheses text[] not null default '{}',
  add column if not exists preconisations_reserves text;

drop function if exists public.expert_send_report(uuid, text, jsonb);

create or replace function public.expert_send_report(p_mandate_id uuid, p_conclusion text, p_rooms jsonb,
                                                     p_hypotheses text[] default null, p_preconisations text default null)
 returns uuid language plpgsql security definer set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v_report uuid; r jsonb; v_pos int := 0;
        v_hyp text[];
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
    if v_m.status <> 'in_progress' then
        raise exception 'Le rapport ne peut être envoyé que pour un mandat en cours (statut actuel : %)', v_m.status;
    end if;
    if p_rooms is null or jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) = 0 then
        raise exception 'Ajoutez au moins une pièce investiguée avant d''envoyer le rapport';
    end if;

    -- hypothèses : on ne garde que les lignes renseignées
    select coalesce(array_agg(trim(h)), '{}') into v_hyp
      from unnest(coalesce(p_hypotheses, '{}')) h where nullif(trim(h), '') is not null;

    insert into public.rdf_reports (mandate_id, created_by, rapport_conclusions, hypotheses, preconisations_reserves, status, submitted_at)
    values (p_mandate_id, auth.uid(), nullif(trim(coalesce(p_conclusion,'')),''), v_hyp,
            nullif(trim(coalesce(p_preconisations,'')),''), 'submitted', now())
    returning id into v_report;

    for r in select * from jsonb_array_elements(p_rooms) loop
        v_pos := v_pos + 1;
        if nullif(trim(coalesce(r->>'room','')),'') is null then raise exception 'Pièce manquante (ligne %)', v_pos; end if;
        insert into public.rdf_report_rooms (report_id, mandate_id, step, position, room, wall, matiere, infiltration,
            moisissure, peinture_endommagee, gaz_detecte, sonde_type, sonde_percent, commentaire, photos)
        values (v_report, p_mandate_id, (r->>'step')::smallint, v_pos, r->>'room', nullif(r->>'wall',''), nullif(r->>'matiere',''),
            (r->>'infiltration')::boolean, (r->>'moisissure')::boolean, (r->>'peinture')::boolean, (r->>'gaz_detecte')::boolean,
            nullif(r->>'sonde_type',''), nullif(replace(replace(r->>'sonde_percent','%',''),',','.'),'')::numeric,
            nullif(r->>'commentaire',''),
            coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(r->'photos','[]'::jsonb)) x), '{}'));
    end loop;

    perform public.transition_mandate_status(p_mandate_id, 'waiting_report');
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
    values (v_expert, 'report_submitted', p_mandate_id,
            jsonb_build_object('report_id', v_report, 'rooms', jsonb_array_length(p_rooms), 'hypotheses', cardinality(v_hyp)));
    return v_report;
end;
$function$;

revoke execute on function public.expert_send_report(uuid, text, jsonb, text[], text) from public, anon;
grant execute on function public.expert_send_report(uuid, text, jsonb, text[], text) to authenticated, service_role;
