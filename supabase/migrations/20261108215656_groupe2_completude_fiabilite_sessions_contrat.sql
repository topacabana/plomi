-- 6. Type de contrat
alter table public.experts add column if not exists contract_type text
  check (contract_type is null or contract_type in ('AE','EI','EURL','SARL','SAS','SASU','SA','Autre'));

-- 7. Sessions (1 mois max)
create table if not exists public.user_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index if not exists user_sessions_user_idx on public.user_sessions (user_id, last_seen_at desc);
alter table public.user_sessions enable row level security;
-- aucune politique : lecture uniquement via les fonctions (security definer)

create or replace function public.touch_presence()
 returns void language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if auth.uid() is null then return; end if;
  update public.user_profiles set last_seen_at = now(), presence_status = 'online' where id = auth.uid();
  select id into v_id from public.user_sessions
   where user_id = auth.uid() and last_seen_at > now() - interval '5 minutes'
   order by last_seen_at desc limit 1;
  if v_id is null then
    insert into public.user_sessions (user_id) values (auth.uid());
  else
    update public.user_sessions set last_seen_at = now() where id = v_id;
  end if;
  delete from public.user_sessions where user_id = auth.uid() and last_seen_at < now() - interval '31 days';
end $$;

create or replace function public.purge_user_sessions() returns void language sql security definer set search_path to 'public' as $$
  delete from public.user_sessions where last_seen_at < now() - interval '31 days';
$$;
revoke all on function public.purge_user_sessions() from public, anon, authenticated;
select cron.schedule('purge_user_sessions', '17 3 * * *', 'select public.purge_user_sessions()')
 where not exists (select 1 from cron.job where jobname = 'purge_user_sessions');

-- 4. Complétude d'un rapport : chaque champ renseigné
create or replace function public.report_is_complete(p_report_id uuid)
 returns boolean language sql stable security definer set search_path to 'public' as $$
  select nullif(trim(coalesce(r.rapport_conclusions,'')),'') is not null
     and nullif(trim(coalesce(r.preconisations_reserves,'')),'') is not null
     and coalesce(cardinality(r.hypotheses),0) > 0
     and (m.mandate_type::text = 'visio' or (
          exists (select 1 from public.rdf_report_rooms rr where rr.report_id = r.id)
          and not exists (
            select 1 from public.rdf_report_rooms rr where rr.report_id = r.id and (
              nullif(trim(coalesce(rr.room,'')),'') is null
              or nullif(trim(coalesce(rr.commentaire,'')),'') is null
              or coalesce(cardinality(rr.photos),0) = 0
              or (rr.step in (1,2) and rr.infiltration is null)
              or (rr.step = 3 and rr.gaz_detecte is null)
              or (rr.step = 4 and (nullif(trim(coalesce(rr.wall,'')),'') is null or nullif(trim(coalesce(rr.matiere,'')),'') is null
                                   or rr.sonde_type is null or rr.sonde_percent is null))))))
    from public.rdf_reports r join public.mandates m on m.id = r.mandate_id
   where r.id = p_report_id;
$$;
revoke all on function public.report_is_complete(uuid) from public, anon;

-- Indicateurs d'un expert sur une période (complétude, fiabilité, sessions)
create or replace function public.expert_quality_stats(p_expert_id uuid, p_start timestamptz default null, p_end timestamptz default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare t0 timestamptz := coalesce(p_start, '2000-01-01'); t1 timestamptz := coalesce(p_end, now());
        v_user uuid; v jsonb; s0 timestamptz; v_days int; f numeric[]; x numeric;
        n_ass int; n_ref int; n_abd int; n_susp int; n_rep int; n_rej int; n_comp int; n_delai int; n_delai_ok int; v_cre numeric;
begin
  select user_id into v_user from public.experts where id = p_expert_id;
  select count(*), count(*) filter (where refused_at is not null) into n_ass, n_ref
    from public.mandate_assignments where expert_id = p_expert_id and assigned_at >= t0 and assigned_at < t1;
  select count(*) filter (where coalesce(l.new_values_json->>'motif', l.new_values_json->>'comment','') ilike 'Abandon expert%'),
         count(*)
    into n_abd, n_susp
    from public.activity_logs l
   where l.entity_type = 'mandate' and l.action = 'status_transition' and l.new_values_json->>'status' = 'suspended'
     and l.created_at >= t0 and l.created_at < t1
     and exists (select 1 from public.mandate_assignments a where a.mandate_id = l.entity_id and a.expert_id = p_expert_id);
  select count(*), count(*) filter (where r.rejected_at is not null), count(*) filter (where public.report_is_complete(r.id)),
         count(*) filter (where m.started_at is not null),
         count(*) filter (where m.started_at is not null and r.submitted_at <= m.started_at + interval '2 hours')
    into n_rep, n_rej, n_comp, n_delai, n_delai_ok
    from public.rdf_reports r join public.mandates m on m.id = r.mandate_id
   where r.created_by = v_user and r.submitted_at is not null and r.submitted_at >= t0 and r.submitted_at < t1;
  select round(100.0 * count(*) filter (where m.arrived_at <= coalesce(m.selected_slot_at, m.slot_1_at) + interval '15 minutes') / nullif(count(*),0))
    into v_cre from public.mandates m
   where m.assigned_expert_id = p_expert_id and m.arrived_at is not null and coalesce(m.selected_slot_at, m.slot_1_at) is not null
     and m.arrived_at >= t0 and m.arrived_at < t1;

  f := array[
    case when n_ass > 0 then 100.0 * (1 - n_ref::numeric / n_ass) end,             -- attributions acceptées
    case when n_ass > 0 then greatest(0, 100.0 * (1 - n_abd::numeric / n_ass)) end, -- pas d'abandon
    case when n_ass > 0 then greatest(0, 100.0 * (1 - n_susp::numeric / n_ass)) end,-- pas de suspension
    v_cre,                                                                          -- respect des créneaux
    case when n_rep > 0 then 100.0 * (1 - n_rej::numeric / n_rep) end,              -- rapports non refusés
    case when n_rep > 0 then 100.0 * n_comp / n_rep end,                            -- complétude
    case when n_delai > 0 then 100.0 * n_delai_ok / n_delai end];                   -- rapport envoyé sous 2 h
  select round(avg(y)) into x from unnest(f) y where y is not null;

  -- sessions (conservées 1 mois)
  s0 := greatest(t0, now() - interval '31 days');
  v_days := greatest(1, ceil(extract(epoch from (least(t1, now()) - s0)) / 86400));
  v := jsonb_build_object(
    'completude', case when n_rep > 0 then round(100.0 * n_comp / n_rep) end,
    'fiabilite', x,
    'fiabilite_detail', jsonb_build_object('attributions_acceptees', round(f[1]), 'sans_abandon', round(f[2]), 'sans_suspension', round(f[3]),
                          'respect_creneaux', round(f[4]), 'rapports_acceptes', round(f[5]), 'completude', round(f[6]), 'envoi_sous_2h', round(f[7])),
    'temps_app_h', (select round(sum(extract(epoch from (least(last_seen_at, t1) - greatest(started_at, s0)))) / 3600.0, 1)
                      from public.user_sessions where user_id = v_user and last_seen_at > s0 and started_at < t1),
    'amplitude_h', (select round(avg(extract(epoch from (fin - debut)) / 3600.0), 1) from (
                      select date_trunc('day', started_at) j, min(started_at) debut, max(last_seen_at) fin
                        from public.user_sessions where user_id = v_user and last_seen_at > s0 and started_at < t1 group by 1) d),
    'disponibilite', (select round(100.0 * count(distinct date_trunc('day', started_at)) / v_days)
                        from public.user_sessions where user_id = v_user and last_seen_at > s0 and started_at < t1));
  if not exists (select 1 from public.user_sessions where user_id = v_user and last_seen_at > s0 and started_at < t1) then
    v := v || jsonb_build_object('temps_app_h', null, 'amplitude_h', null, 'disponibilite', null);
  end if;
  return v;
end $$;
revoke all on function public.expert_quality_stats(uuid, timestamptz, timestamptz) from public, anon, authenticated;
