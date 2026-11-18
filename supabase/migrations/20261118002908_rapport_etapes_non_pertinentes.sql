-- Étapes RDF déclarées « non pertinentes » par l'expert (ex. fuite trouvée sur une vanne : pas de gaz traceur).
-- Seules les étapes 2 à 4 peuvent l'être ; l'inspection visuelle (étape 1) reste obligatoire.
-- Le choix est enregistré avec le rapport, apparaît dans le PDF et reste visible du gestionnaire.

alter table public.rdf_reports
    add column if not exists skipped_steps smallint[] not null default '{}';

alter table public.rdf_reports drop constraint if exists rdf_reports_skipped_steps_chk;
alter table public.rdf_reports
    add constraint rdf_reports_skipped_steps_chk check (skipped_steps <@ array[2, 3, 4]::smallint[]);

comment on column public.rdf_reports.skipped_steps is
    'Étapes RDF (2 = colorant et fluorine, 3 = gaz traceur, 4 = relevé de sonde) déclarées non pertinentes par l''expert.';

-- expert_send_report : nouveau paramètre p_skipped_steps (facultatif, rétrocompatible)
drop function if exists public.expert_send_report(uuid, text, jsonb, text[], text);

create function public.expert_send_report(
    p_mandate_id uuid,
    p_conclusion text,
    p_rooms jsonb,
    p_hypotheses text[] default null,
    p_preconisations text default null,
    p_skipped_steps smallint[] default null)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v_report uuid; r jsonb; v_pos int := 0;
        v_hyp text[]; v_skip smallint[];
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
    if v_m.status <> 'in_progress' then
        raise exception 'Le rapport ne peut être envoyé que pour un mandat en cours (statut actuel : %)', v_m.status;
    end if;

    if v_m.mandate_type::text = 'rdfs' and not exists (select 1 from public.destructive_consents dc where dc.mandate_id = p_mandate_id) then
        raise exception 'RDFS : l''accord du bénéficiaire pour les investigations destructives doit être enregistré avant le rapport';
    end if;
    if v_m.mandate_type::text <> 'visio' and (p_rooms is null or jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) = 0) then
        raise exception 'Ajoutez au moins une pièce investiguée avant d''envoyer le rapport';
    end if;

    -- hypothèses : on ne garde que les lignes renseignées
    select coalesce(array_agg(trim(h)), '{}') into v_hyp
      from unnest(coalesce(p_hypotheses, '{}')) h where nullif(trim(h), '') is not null;

    -- étapes non pertinentes : uniquement 2, 3, 4 (RDF), sans doublon
    select coalesce(array_agg(distinct s order by s), '{}') into v_skip
      from unnest(coalesce(p_skipped_steps, '{}')) s where s in (2, 3, 4);
    if v_m.mandate_type::text <> 'rdf' then v_skip := '{}'; end if;

    insert into public.rdf_reports (mandate_id, created_by, rapport_conclusions, hypotheses, preconisations_reserves,
                                    skipped_steps, status, submitted_at)
    values (p_mandate_id, auth.uid(), nullif(trim(coalesce(p_conclusion,'')),''), v_hyp,
            nullif(trim(coalesce(p_preconisations,'')),''), v_skip, 'submitted', now())
    returning id into v_report;

    if v_m.mandate_type::text = 'visio' and nullif(trim(coalesce(p_conclusion,'')),'') is null then
        raise exception 'La conclusion est obligatoire pour une visio expertise';
    end if;
    for r in select * from jsonb_array_elements(coalesce(p_rooms, '[]'::jsonb)) loop
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
            jsonb_build_object('report_id', v_report, 'rooms', jsonb_array_length(p_rooms), 'hypotheses', cardinality(v_hyp),
                               'skipped_steps', to_jsonb(v_skip)));
    return v_report;
end;
$function$;

revoke all on function public.expert_send_report(uuid, text, jsonb, text[], text, smallint[]) from public, anon;
grant execute on function public.expert_send_report(uuid, text, jsonb, text[], text, smallint[]) to authenticated, service_role;
