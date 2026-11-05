create table if not exists public.rdf_report_rooms (
  id            uuid primary key default gen_random_uuid(),
  report_id     uuid not null references public.rdf_reports(id) on delete cascade,
  mandate_id    uuid not null references public.mandates(id) on delete cascade,
  step          smallint not null check (step between 1 and 4),
  position      smallint not null default 1,
  room          text not null,
  wall          text,
  matiere       text,
  infiltration  boolean,          -- true = constatée, false = non constatée, null = non renseigné (étapes 1 et 2)
  moisissure    boolean,          -- étape 1
  peinture_endommagee boolean,    -- étape 1
  gaz_detecte   boolean,          -- étape 3 : true / false / null
  sonde_type    text check (sonde_type in ('picot','boule')),  -- étape 4
  sonde_percent numeric check (sonde_percent between 0 and 100),
  commentaire   text,
  photos        text[] not null default '{}',
  created_at    timestamptz not null default now()
);
comment on table public.rdf_report_rooms is 'Pièces investiguées d''un rapport RDF : une ligne par pièce et par étape (1 inspection, 2 colorant/fluorine, 3 gaz traceur, 4 relevé de sonde).';
create index if not exists rdf_report_rooms_report_idx on public.rdf_report_rooms(report_id, step, position);
create index if not exists rdf_report_rooms_mandate_idx on public.rdf_report_rooms(mandate_id);

alter table public.rdf_report_rooms enable row level security;
create policy "rooms: lecture utilisateurs connectes" on public.rdf_report_rooms for select to authenticated using (true);
grant select on public.rdf_report_rooms to authenticated;

create or replace function public.expert_send_report(p_mandate_id uuid, p_conclusion text, p_rooms jsonb)
 returns uuid language plpgsql security definer set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v_report uuid; r jsonb; v_pos int := 0;
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

    insert into public.rdf_reports (mandate_id, created_by, rapport_conclusions, status, submitted_at)
    values (p_mandate_id, auth.uid(), nullif(trim(coalesce(p_conclusion,'')),''), 'submitted', now())
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
    values (v_expert, 'report_submitted', p_mandate_id, jsonb_build_object('report_id', v_report, 'rooms', jsonb_array_length(p_rooms)));
    return v_report;
end;
$function$;
grant execute on function public.expert_send_report(uuid, text, jsonb) to authenticated;
