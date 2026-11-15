-- RGPD B4 : traçabilité des sélections automatiques (PLO) et contestation (art. 22).
-- 1. Chaque application de la PLO enregistre une « décision » : seuils utilisés et,
--    pour chaque expert de l'organisation, ses 4 scores et s'il a été retenu.
-- 2. L'expert consulte les décisions qui le concernent (ses scores face aux seuils,
--    jamais ceux des autres) et peut demander une révision humaine.
-- 3. Le superviseur de l'organisation traite les contestations (réponse obligatoire).
-- Conservation : décisions et contestations 12 mois (purge mensuelle).

create table if not exists public.plo_decisions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  decided_by uuid references auth.users(id) on delete set null,
  strategy_id uuid,
  thresholds jsonb not null,
  include_no_data boolean not null default false,
  selected_count int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.plo_decision_experts (
  decision_id uuid not null references public.plo_decisions(id) on delete cascade,
  expert_id uuid not null references public.experts(id) on delete cascade,
  included boolean not null,
  precision_score int,
  reactivite_score int,
  rapidite_score int,
  avis_client_score int,
  primary key (decision_id, expert_id)
);
create index if not exists plo_decision_experts_expert_idx on public.plo_decision_experts (expert_id);

create table if not exists public.plo_contestations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  expert_id uuid not null references public.experts(id) on delete cascade,
  decision_id uuid references public.plo_decisions(id) on delete set null,
  motif text not null,
  status text not null default 'ouverte' check (status in ('ouverte','acceptee','rejetee')),
  response text,
  handled_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  handled_at timestamptz
);

alter table public.plo_decisions enable row level security;
alter table public.plo_decision_experts enable row level security;
alter table public.plo_contestations enable row level security;
-- Aucun accès direct : tout passe par les fonctions ci-dessous.
revoke all on public.plo_decisions, public.plo_decision_experts, public.plo_contestations from anon, authenticated;

-- 1. plo_select enregistre désormais la décision complète.
create or replace function public.plo_select(p_precision integer, p_reactivite integer, p_rapidite integer,
  p_avis_client integer, p_include_no_data boolean default false, p_strategy_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ids jsonb;
  v_org uuid := public.current_user_organization_id();
  v_decision uuid;
  v_scores jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_scores from public.plo_expert_scores() x;

  select coalesce(jsonb_agg(expert_id), '[]'::jsonb) into v_ids
    from jsonb_to_recordset(v_scores) as s(expert_id uuid, precision_score int, reactivite_score int, rapidite_score int, avis_client_score int)
   where (case when s.precision_score   is null then coalesce(p_include_no_data, false) else s.precision_score   >= coalesce(p_precision, 0) end)
     and (case when s.reactivite_score  is null then coalesce(p_include_no_data, false) else s.reactivite_score  >= coalesce(p_reactivite, 0) end)
     and (case when s.rapidite_score    is null then coalesce(p_include_no_data, false) else s.rapidite_score    >= coalesce(p_rapidite, 0) end)
     and (case when s.avis_client_score is null then coalesce(p_include_no_data, false) else s.avis_client_score >= coalesce(p_avis_client, 0) end);

  if v_org is not null then
    insert into public.plo_decisions (organization_id, decided_by, strategy_id, thresholds, include_no_data, selected_count)
    values (v_org, auth.uid(), p_strategy_id,
            jsonb_build_object('precision', p_precision, 'reactivite', p_reactivite,
                               'rapidite', p_rapidite, 'avis_client', p_avis_client),
            coalesce(p_include_no_data, false), jsonb_array_length(v_ids))
    returning id into v_decision;

    insert into public.plo_decision_experts (decision_id, expert_id, included,
                precision_score, reactivite_score, rapidite_score, avis_client_score)
    select v_decision, s.expert_id, v_ids ? s.expert_id::text,
           s.precision_score, s.reactivite_score, s.rapidite_score, s.avis_client_score
      from jsonb_to_recordset(v_scores) as s(expert_id uuid, precision_score int, reactivite_score int, rapidite_score int, avis_client_score int)
      join public.org_experts oe on oe.expert_id = s.expert_id and oe.organization_id = v_org
    on conflict do nothing;
  end if;

  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', coalesce(p_strategy_id, gen_random_uuid()), 'plo_applied',
          jsonb_build_object('strategy_id', p_strategy_id, 'decision_id', v_decision,
                             'precision', p_precision, 'reactivite', p_reactivite,
                             'rapidite', p_rapidite, 'avis_client', p_avis_client,
                             'include_no_data', p_include_no_data, 'selected', jsonb_array_length(v_ids)));
  return v_ids;
end;
$$;

-- 2a. L'expert voit les décisions qui le concernent (90 derniers jours, 50 max).
create or replace function public.expert_plo_decisions()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare v_expert uuid;
begin
  select id into v_expert from public.experts where user_id = auth.uid() limit 1;
  if v_expert is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by x->>'le' desc) from (
      select jsonb_build_object(
        'decision_id', d.id,
        'le', d.created_at,
        'organisation', o.name,
        'retenu', de.included,
        'seuils', d.thresholds,
        'scores', jsonb_build_object('precision', de.precision_score, 'reactivite', de.reactivite_score,
                                     'rapidite', de.rapidite_score, 'avis_client', de.avis_client_score),
        'sans_donnees_admis', d.include_no_data,
        'explication', case when de.included then 'Retenu : vos scores atteignent tous les seuils.'
          else 'Non retenu : ' || coalesce(nullif(concat_ws(', ',
            case when de.precision_score   is null and not d.include_no_data then 'précision (pas encore de données)'
                 when de.precision_score   < coalesce((d.thresholds->>'precision')::int, 0)   then 'précision ' || de.precision_score || ' < ' || (d.thresholds->>'precision') end,
            case when de.reactivite_score  is null and not d.include_no_data then 'réactivité (pas encore de données)'
                 when de.reactivite_score  < coalesce((d.thresholds->>'reactivite')::int, 0)  then 'réactivité ' || de.reactivite_score || ' < ' || (d.thresholds->>'reactivite') end,
            case when de.rapidite_score    is null and not d.include_no_data then 'rapidité (pas encore de données)'
                 when de.rapidite_score    < coalesce((d.thresholds->>'rapidite')::int, 0)    then 'rapidité ' || de.rapidite_score || ' < ' || (d.thresholds->>'rapidite') end,
            case when de.avis_client_score is null and not d.include_no_data then 'avis client (pas encore de données)'
                 when de.avis_client_score < coalesce((d.thresholds->>'avis_client')::int, 0) then 'avis client ' || de.avis_client_score || ' < ' || (d.thresholds->>'avis_client') end
          ), ''), 'seuil non atteint') || '.' end,
        'contestation', (select jsonb_build_object('statut', c.status, 'reponse', c.response)
                           from public.plo_contestations c
                          where c.decision_id = d.id and c.expert_id = v_expert
                          order by c.created_at desc limit 1)
      ) x
      from public.plo_decision_experts de
      join public.plo_decisions d on d.id = de.decision_id
      left join public.organizations o on o.id = d.organization_id
      where de.expert_id = v_expert and d.created_at > now() - interval '90 days'
      order by d.created_at desc limit 50
    ) t), '[]'::jsonb);
end;
$$;

-- 2b. L'expert demande une révision humaine d'une décision.
create or replace function public.expert_plo_contest(p_decision_id uuid, p_motif text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_expert uuid; v_org uuid; v_id uuid;
begin
  select id into v_expert from public.experts where user_id = auth.uid() limit 1;
  if v_expert is null then return jsonb_build_object('ok', false, 'error', 'Aucune fiche expert rattachée à ce compte.'); end if;
  if length(trim(coalesce(p_motif, ''))) < 10 then
    return jsonb_build_object('ok', false, 'error', 'Expliquez votre demande en quelques mots (10 caractères minimum).');
  end if;
  select d.organization_id into v_org
    from public.plo_decisions d join public.plo_decision_experts de on de.decision_id = d.id
   where d.id = p_decision_id and de.expert_id = v_expert;
  if v_org is null then return jsonb_build_object('ok', false, 'error', 'Sélection introuvable.'); end if;
  if exists (select 1 from public.plo_contestations where decision_id = p_decision_id and expert_id = v_expert and status = 'ouverte') then
    return jsonb_build_object('ok', false, 'error', 'Une demande est déjà en cours pour cette sélection.');
  end if;
  insert into public.plo_contestations (organization_id, expert_id, decision_id, motif)
  values (v_org, v_expert, p_decision_id, left(trim(p_motif), 2000)) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- 3a. Le superviseur liste les contestations de son organisation.
create or replace function public.plo_contestations_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_supervisor() then raise exception 'Réservé au superviseur'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'expert', concat_ws(' ', e.first_name, e.last_name), 'societe', e.company_name,
      'motif', c.motif, 'statut', c.status, 'reponse', c.response,
      'recue_le', c.created_at, 'traitee_le', c.handled_at,
      'decision_le', d.created_at, 'seuils', d.thresholds,
      'retenu', de.included,
      'scores', jsonb_build_object('precision', de.precision_score, 'reactivite', de.reactivite_score,
                                   'rapidite', de.rapidite_score, 'avis_client', de.avis_client_score)
    ) order by (c.status = 'ouverte') desc, c.created_at desc)
    from public.plo_contestations c
    join public.experts e on e.id = c.expert_id
    left join public.plo_decisions d on d.id = c.decision_id
    left join public.plo_decision_experts de on de.decision_id = c.decision_id and de.expert_id = c.expert_id
    where c.organization_id = v_org), '[]'::jsonb);
end;
$$;

-- 3b. Le superviseur répond (réponse obligatoire) ; l'expert est notifié.
create or replace function public.plo_contestation_close(p_id uuid, p_status text, p_response text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_org uuid := public.current_user_organization_id(); v_user uuid;
begin
  if not public.is_supervisor() then raise exception 'Réservé au superviseur'; end if;
  if p_status not in ('acceptee','rejetee') then
    return jsonb_build_object('ok', false, 'error', 'Statut invalide.');
  end if;
  if length(trim(coalesce(p_response, ''))) < 10 then
    return jsonb_build_object('ok', false, 'error', 'La réponse à l''expert est obligatoire (10 caractères minimum).');
  end if;
  update public.plo_contestations
     set status = p_status, response = left(trim(p_response), 2000), handled_by = auth.uid(), handled_at = now()
   where id = p_id and organization_id = v_org and status = 'ouverte'
  returning (select user_id from public.experts where id = plo_contestations.expert_id) into v_user;
  if not found then return jsonb_build_object('ok', false, 'error', 'Contestation introuvable ou déjà traitée.'); end if;
  if v_user is not null then
    insert into public.notifications (user_id, type, title, body, channel)
    values (v_user, 'system', 'Réponse à votre contestation',
            case when p_status = 'acceptee' then 'Votre demande de révision a été acceptée : ' else 'Votre demande de révision a été examinée : ' end
            || left(trim(p_response), 500), 'in_app');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.plo_select(integer, integer, integer, integer, boolean, uuid),
  public.expert_plo_decisions(), public.expert_plo_contest(uuid, text),
  public.plo_contestations_list(), public.plo_contestation_close(uuid, text, text) from public, anon;
grant execute on function public.plo_select(integer, integer, integer, integer, boolean, uuid),
  public.expert_plo_decisions(), public.expert_plo_contest(uuid, text),
  public.plo_contestations_list(), public.plo_contestation_close(uuid, text, text) to authenticated, service_role;

-- Conservation : 12 mois.
select cron.schedule('purge_plo_decisions', '37 4 2 * *', $c$
  delete from public.plo_contestations where created_at < now() - interval '12 months' and status <> 'ouverte';
  delete from public.plo_decisions d where d.created_at < now() - interval '12 months'
    and not exists (select 1 from public.plo_contestations c where c.decision_id = d.id and c.status = 'ouverte');
$c$);
