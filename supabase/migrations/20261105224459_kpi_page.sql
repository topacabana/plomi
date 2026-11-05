create table if not exists public.kpi_favorites (
  user_id uuid not null references public.user_profiles(id) on delete cascade,
  kpi_code text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, kpi_code)
);
alter table public.kpi_favorites enable row level security;
drop policy if exists "kpi_favorites : les miens" on public.kpi_favorites;
create policy "kpi_favorites : les miens" on public.kpi_favorites
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.kpi_catalog()
 returns jsonb language sql immutable set search_path to 'public'
as $$
  select jsonb_agg(jsonb_build_object('code', c, 'label', l, 'theme', t, 'unit', u, 'scope', s, 'available', a) order by o)
  from (values
   ('temps_app','Temps passé sur l''app','Disponibilité','h','expert',false,1),
   ('amplitude_horaire','Amplitude horaire','Disponibilité','h','expert',false,2),
   ('reactivite','Temps de réactivité aux nouvelles demandes de mandats','Réactivité','min','expert',true,3),
   ('temps_deplacement','Temps de déplacement à domicile','Traitement','min','expert',false,4),
   ('temps_visio','Temps de visio','Traitement','min','expert',false,5),
   ('temps_rapport_visio','Temps de réalisation rapport (visio)','Traitement','min','expert',true,6),
   ('temps_rapport_rdf','Temps de réalisation rapport par investigations (RDF)','Traitement','min','expert',true,7),
   ('temps_rapport_rdfs','Temps de réalisation rapport (RDFS)','Traitement','min','expert',true,8),
   ('visio_jour','Nombre de visio / jour','Nombre de mandats','/j','expert',true,9),
   ('rdf_jour','Nombre de RDF / jour','Nombre de mandats','/j','expert',true,10),
   ('rdfs_jour','Nombre de RDFS / jour','Nombre de mandats','/j','expert',true,11),
   ('mots_conclusion','Nombre de mots par conclusion','Précision de rapport','mots','expert',true,12),
   ('mots_rapport','Nombre de mots par rapport','Précision de rapport','mots','expert',true,13),
   ('pieces_investiguees','Nombre de pièces investiguées','Précision de rapport','pièces','expert',true,14),
   ('redrops','Nombre de redrop de mandat','Traitement','nb','both',true,15),
   ('photos_rapport','Nombre de photos par rapport','Nombre de média','photos','expert',true,16),
   ('videos_rapport','Nombre de vidéos par rapport (RDF ; RDFS)','Nombre de média','vidéos','expert',false,17),
   ('nb_avis_client','Nombre d''avis client','Compétence et professionnalisme','nb','expert',false,18),
   ('nb_listes_affilie','Nombre de listes affiliées','Compétence et professionnalisme','nb','expert',true,19),
   ('nb_zones_affilie','Nombre de zones affiliées','Géographique','nb','expert',true,20),
   ('suspensions','Nombre de suspensions','Traitement','nb','both',true,21),
   ('note_client_min','Note client minimum','Compétence et professionnalisme','/5','expert',true,22),
   ('note_client_max','Note client maximum','Compétence et professionnalisme','/5','expert',true,23),
   ('note_client_moy','Note client moyenne','Compétence et professionnalisme','/5','expert',true,24),
   ('note_app_min','Note app minimum','Compétence et professionnalisme','/5','expert',false,25),
   ('note_app_max','Note app maximum','Compétence et professionnalisme','/5','expert',false,26),
   ('note_app_moy','Note app moyenne','Compétence et professionnalisme','/5','expert',false,27),
   ('note_mandataire_min','Note mandataire minimum','Compétence et professionnalisme','/5','expert',false,28),
   ('note_mandataire_max','Note mandataire maximum','Compétence et professionnalisme','/5','expert',false,29),
   ('note_mandataire_moy','Note mandataire moyenne','Compétence et professionnalisme','/5','expert',false,30),
   ('temps_avant_drop','Temps de gestion avant drop de mandats','Traitement','h','mandataire',true,31),
   ('temps_sur_drop','Temps de mise à disposition de mandats sur le drop','Traitement','h','both',true,32),
   ('attrib_visio','Temps avant attribution de mandats visio','Réactivité','h','both',true,33),
   ('attrib_rdf','Temps avant attribution de mandats RDF','Réactivité','h','both',true,34),
   ('attrib_rdfs','Temps avant attribution de mandats RDFS','Réactivité','h','both',true,35),
   ('traitement_visio','Temps de traitement mandats visio','Traitement','h','both',true,36),
   ('traitement_rdf','Temps de traitement mandats RDF','Traitement','h','both',true,37),
   ('traitement_rdfs','Temps de traitement mandats RDFS','Traitement','h','both',true,38),
   ('temps_reattribution','Temps de réattribution mandat (visio ; RDF ; RDFS)','Réactivité','h','mandataire',false,39),
   ('temps_suspension','Temps de suspension moyen','Traitement','h','mandataire',false,40),
   ('demandes_mois','Nombre de demandes de mandats / mois (visio ; RDF ; RDFS)','Nombre de mandats','/mois','mandataire',true,41),
   ('creation_auto','Nombre de création automatique','Nombre de mandats','nb','mandataire',true,42),
   ('creation_manuelle','Nombre de création manuelle','Nombre de mandats','nb','mandataire',true,43),
   ('redrop_rdf_apres_visio','Nombre de redrop RDF suite à visio','Nombre de mandats','nb','mandataire',false,44),
   ('redrop_rdfs_apres_rdf','Nombre de redrop RDFS suite à RDF','Nombre de mandats','nb','mandataire',false,45),
   ('experts_par_zone','Nombre d''experts par zone','Géographique','texte','mandataire',true,46),
   ('nb_listes','Nombre de listes d''experts','Compétence et professionnalisme','nb','mandataire',true,47),
   ('experts_par_liste','Nombre d''experts par liste','Compétence et professionnalisme','moy.','mandataire',true,48),
   ('clotures','Nombre de clôtures après expertise (visio ; RDF ; RDFS)','Traitement','nb','both',true,49),
   ('recrutements','Nombre de recrutement via PLOMI','Compétence et professionnalisme','nb','mandataire',false,50)
  ) v(c, l, t, u, s, a, o)
$$;

create or replace function public.toggle_kpi_favorite(p_code text)
 returns boolean language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if exists (select 1 from public.kpi_favorites where user_id = auth.uid() and kpi_code = p_code) then
    delete from public.kpi_favorites where user_id = auth.uid() and kpi_code = p_code;
    return false;
  end if;
  insert into public.kpi_favorites (user_id, kpi_code) values (auth.uid(), p_code);
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', gen_random_uuid(), 'kpi_favorite_added', jsonb_build_object('kpi', p_code));
  return true;
end $$;

create or replace function public.kpi_page_data()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return jsonb_build_object(
    'catalog', public.kpi_catalog(),
    'favorites', coalesce((select jsonb_agg(kpi_code) from public.kpi_favorites where user_id = auth.uid()), '[]'::jsonb),
    'experts', public.manual_assignment_data(array['00000000-0000-0000-0000-000000000000']::uuid[])->'experts',
    'lists', public.expert_lists_page_data()->'lists');
end $$;

create or replace function public.kpi_report(p_start date, p_end date, p_scope text, p_expert_ids uuid[], p_kpis text[])
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_org uuid := public.current_user_organization_id();
  t0 timestamptz := coalesce(p_start, current_date - 30)::timestamptz;
  t1 timestamptz := (coalesce(p_end, current_date) + 1)::timestamptz;
  v_days numeric := greatest(1, extract(epoch from (t1 - t0)) / 86400);
  v_months numeric := greatest(1, extract(epoch from (t1 - t0)) / (86400 * 30.44));
  v_rows jsonb := '[]'::jsonb; e record; v jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if t1 <= t0 then raise exception 'La date de fin doit suivre la date de début'; end if;

  if coalesce(p_scope, 'experts') = 'experts' then
    for e in select x.id, x.company_name, x.first_name, x.last_name, x.rating, x.coverage_zone
               from public.experts x where x.id = any(coalesce(p_expert_ids, '{}')) loop
      with a as (
        select ma.*, m.mandate_type, m.drop_at, m.started_at, m.closed_at, m.status
          from public.mandate_assignments ma join public.mandates m on m.id = ma.mandate_id and m.insurance_org_id = v_org
         where ma.expert_id = e.id and ma.assigned_at >= t0 and ma.assigned_at < t1),
      rep as (
        select r.*, m.mandate_type, m.started_at,
               (select count(*) from public.rdf_report_rooms rr where rr.report_id = r.id) rooms,
               coalesce((select sum(cardinality(rr.photos)) from public.rdf_report_rooms rr where rr.report_id = r.id), 0) photos,
               coalesce((select sum(array_length(regexp_split_to_array(trim(rr.commentaire), '\s+'), 1)) from public.rdf_report_rooms rr
                          where rr.report_id = r.id and nullif(trim(rr.commentaire), '') is not null), 0) room_words
          from public.rdf_reports r join public.mandates m on m.id = r.mandate_id and m.insurance_org_id = v_org
          join public.experts x on x.user_id = r.created_by and x.id = e.id
         where r.submitted_at >= t0 and r.submitted_at < t1)
      select jsonb_build_object(
        'reactivite', (select round(avg(extract(epoch from accepted_at - assigned_at) / 60)::numeric, 1) from a where accepted_at is not null),
        'temps_rapport_visio', (select round(avg(extract(epoch from submitted_at - started_at) / 60)::numeric, 1) from rep where mandate_type = 'visio' and started_at is not null),
        'temps_rapport_rdf', (select round(avg(extract(epoch from submitted_at - started_at) / 60)::numeric, 1) from rep where mandate_type = 'rdf' and started_at is not null),
        'temps_rapport_rdfs', (select round(avg(extract(epoch from submitted_at - started_at) / 60)::numeric, 1) from rep where mandate_type = 'rdfs' and started_at is not null),
        'visio_jour', round((select count(*) from a where mandate_type = 'visio') / v_days, 2),
        'rdf_jour', round((select count(*) from a where mandate_type = 'rdf') / v_days, 2),
        'rdfs_jour', round((select count(*) from a where mandate_type = 'rdfs') / v_days, 2),
        'mots_conclusion', (select round(avg(coalesce(array_length(regexp_split_to_array(trim(rapport_conclusions), '\s+'), 1), 0)), 1) from rep),
        'mots_rapport', (select round(avg(coalesce(array_length(regexp_split_to_array(trim(coalesce(rapport_conclusions,'') || ' ' || coalesce(preconisations_reserves,'') || ' ' || array_to_string(hypotheses, ' ')), '\s+'), 1), 0) + room_words), 1) from rep),
        'pieces_investiguees', (select round(avg(rooms), 1) from rep),
        'photos_rapport', (select round(avg(photos), 1) from rep),
        'redrops', (select count(*) from a where comment = 'transition redrop'),
        'suspensions', (select count(*) from public.mandate_history h join a on a.mandate_id = h.mandate_id
                         where h.status_to = 'suspended' and h.created_at >= t0 and h.created_at < t1),
        'nb_listes_affilie', (select count(*) from public.expert_list_members lm join public.expert_lists l on l.id = lm.list_id and l.organization_id = v_org where lm.expert_id = e.id),
        'nb_zones_affilie', (select count(*) from unnest(regexp_split_to_array(coalesce(e.coverage_zone, ''), '\s*,\s*')) z where z <> ''),
        'note_client_min', e.rating, 'note_client_max', e.rating, 'note_client_moy', e.rating,
        'temps_sur_drop', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from a where drop_at is not null),
        'attrib_visio', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from a where mandate_type = 'visio' and drop_at is not null),
        'attrib_rdf', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from a where mandate_type = 'rdf' and drop_at is not null),
        'attrib_rdfs', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from a where mandate_type = 'rdfs' and drop_at is not null),
        'traitement_visio', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from a where mandate_type = 'visio' and closed_at is not null),
        'traitement_rdf', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from a where mandate_type = 'rdf' and closed_at is not null),
        'traitement_rdfs', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from a where mandate_type = 'rdfs' and closed_at is not null),
        'clotures', (select count(*) from a where closed_at >= t0 and closed_at < t1)
      ) into v;
      v_rows := v_rows || jsonb_build_object('id', e.id, 'label', trim(concat_ws(' ', e.company_name, '—', e.first_name, e.last_name)), 'values', v);
    end loop;
  else
    with m as (select * from public.mandates where insurance_org_id = v_org and created_at >= t0 and created_at < t1)
    select jsonb_build_object(
      'temps_avant_drop', (select round(avg(extract(epoch from drop_at - created_at) / 3600)::numeric, 1) from m where drop_at is not null),
      'temps_sur_drop', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from m where drop_at is not null and assigned_at is not null),
      'attrib_visio', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from m where mandate_type = 'visio' and drop_at is not null and assigned_at is not null),
      'attrib_rdf', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from m where mandate_type = 'rdf' and drop_at is not null and assigned_at is not null),
      'attrib_rdfs', (select round(avg(extract(epoch from assigned_at - drop_at) / 3600)::numeric, 1) from m where mandate_type = 'rdfs' and drop_at is not null and assigned_at is not null),
      'traitement_visio', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from m where mandate_type = 'visio' and closed_at is not null and assigned_at is not null),
      'traitement_rdf', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from m where mandate_type = 'rdf' and closed_at is not null and assigned_at is not null),
      'traitement_rdfs', (select round(avg(extract(epoch from closed_at - assigned_at) / 3600)::numeric, 1) from m where mandate_type = 'rdfs' and closed_at is not null and assigned_at is not null),
      'demandes_mois', (select concat_ws(' · ', 'visio ' || round(count(*) filter (where mandate_type = 'visio') / v_months, 1),
                                                'RDF ' || round(count(*) filter (where mandate_type = 'rdf') / v_months, 1),
                                                'RDFS ' || round(count(*) filter (where mandate_type = 'rdfs') / v_months, 1)) from m),
      'creation_auto', (select count(*) from m where created_by_user_id is null),
      'creation_manuelle', (select count(*) from m where created_by_user_id is not null),
      'redrops', (select coalesce(sum(redrop_count), 0) from m),
      'suspensions', (select count(*) from public.mandate_history h join public.mandates mm on mm.id = h.mandate_id and mm.insurance_org_id = v_org
                       where h.status_to = 'suspended' and h.created_at >= t0 and h.created_at < t1),
      'clotures', (select concat_ws(' · ', 'visio ' || count(*) filter (where mm.mandate_type = 'visio'), 'RDF ' || count(*) filter (where mm.mandate_type = 'rdf'),
                                    'RDFS ' || count(*) filter (where mm.mandate_type = 'rdfs'))
                     from public.mandates mm where mm.insurance_org_id = v_org and mm.closed_at >= t0 and mm.closed_at < t1),
      'experts_par_zone', (select string_agg(z || ' : ' || n, ' · ' order by n desc, z) from (
                             select z, count(distinct x.id) n from public.experts x,
                                    unnest(regexp_split_to_array(coalesce(x.coverage_zone, ''), '\s*,\s*')) z
                              where z <> '' group by z) s),
      'nb_listes', (select count(*) from public.expert_lists where organization_id = v_org and is_active),
      'experts_par_liste', (select round(avg(n), 1) from (select count(lm.expert_id) n from public.expert_lists l
                              left join public.expert_list_members lm on lm.list_id = l.id
                             where l.organization_id = v_org and l.is_active group by l.id) s)
    ) into v;
    v_rows := jsonb_build_array(jsonb_build_object('id', v_org, 'label', (select name from public.organizations where id = v_org), 'values', v));
  end if;

  if coalesce(cardinality(p_kpis), 0) > 0 then
    select coalesce(jsonb_agg(r || jsonb_build_object('values',
             (select coalesce(jsonb_object_agg(k, val), '{}'::jsonb) from jsonb_each(r->'values') x(k, val) where k = any(p_kpis)))), '[]'::jsonb)
      into v_rows from jsonb_array_elements(v_rows) r;
  end if;

  return jsonb_build_object('start', t0::date, 'end', (t1 - interval '1 day')::date, 'scope', coalesce(p_scope, 'experts'), 'rows', v_rows);
end $$;

revoke execute on function public.kpi_catalog() from public, anon;
revoke execute on function public.toggle_kpi_favorite(text) from public, anon;
revoke execute on function public.kpi_page_data() from public, anon;
revoke execute on function public.kpi_report(date, date, text, uuid[], text[]) from public, anon;
grant execute on function public.kpi_catalog() to authenticated, service_role;
grant execute on function public.toggle_kpi_favorite(text) to authenticated, service_role;
grant execute on function public.kpi_page_data() to authenticated, service_role;
grant execute on function public.kpi_report(date, date, text, uuid[], text[]) to authenticated, service_role;
