-- Séparation gestionnaire / superviseur (24/11/2026).
-- Le gestionnaire ne garde que les commandes du traitement conventionnel d'un dossier
-- (créer, dropper, attribuer, redropper après abandon, valider et clôturer).
-- Tout ce qui sort du cycle normal est réservé au superviseur :
--   message groupé, suspension et levée de suspension d'un expert, reprise d'un mandat suspendu,
--   réattribution, purge des archives, assureurs, listes d'experts, recrutement,
--   stratégies PLO, KPIs, et les transitions hors process (suppression, pause, reprise,
--   clôture sans suite, retrait du drop ou de l'attribution).

-- 1. Fonctions : après le contrôle « gestionnaire », un second contrôle « superviseur ».
do $mig$
declare
  f text;
  v_def text;
  v_new text;
begin
  foreach f in array array[
    'manager_broadcast', 'suspend_expert', 'lift_expert_suspension', 'resume_mandate',
    'manager_archives_purge', 'insurer_save', 'insurer_archive', 'insurer_delete',
    'save_expert_list', 'duplicate_expert_list', 'add_experts_to_lists', 'recruit_experts',
    'save_plo_strategy', 'delete_plo_strategy', 'kpi_report', 'kpi_page_data', 'toggle_kpi_favorite']
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f;
    if v_def is null then raise exception 'Fonction % introuvable', f; end if;
    if v_def like '%Réservé au superviseur%' then continue; end if;
    v_new := regexp_replace(v_def,
      '(if not public\.is_manager\(\) then\s+raise exception ''[^'']*''(\s+using errcode = ''42501'')?;\s*end if;)',
      E'\\1\n  if not public.is_supervisor() then raise exception ''Réservé au superviseur'' using errcode = ''42501''; end if;');
    if v_new = v_def then raise exception 'Contrôle gestionnaire non trouvé dans %', f; end if;
    execute v_new;
  end loop;

  -- La réattribution renvoie un objet d'erreur au lieu de lever une exception.
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'manager_reassign_mandate';
  if v_def not like '%Réservé au superviseur%' then
    v_new := regexp_replace(v_def,
      '(if not public\.is_manager\(\) then\s+return jsonb_build_object\(''ok'', false, ''error'', ''Réservé aux gestionnaires\.''\);\s*end if;)',
      E'\\1\n  if not public.is_supervisor() then\n    return jsonb_build_object(''ok'', false, ''error'', ''Réservé au superviseur.'');\n  end if;');
    if v_new = v_def then raise exception 'Contrôle gestionnaire non trouvé dans manager_reassign_mandate'; end if;
    execute v_new;
  end if;
end
$mig$;

-- 2. Transitions hors process : refusées à un gestionnaire non superviseur quand elles sont
--    demandées directement par l'application (RPC transition_mandate_status ou écriture sur la table).
--    Les fonctions du cycle normal (abandon, redrop, attribution, rapport...) ne sont pas concernées.
create or replace function public.is_off_process_transition(p_old mandate_status, p_new mandate_status)
returns boolean
language sql
immutable
set search_path to 'public'
as $$
  select p_new in ('cancelled', 'suspended')
      or p_old = 'suspended'
      or (p_new = 'closed' and p_old <> 'waiting_report')
      or (p_new = 'drop_pending' and p_old in ('dropped', 'redrop', 'assigned', 'in_progress', 'waiting_report'));
$$;

create or replace function public.trg_guard_off_process_transition()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_path text := coalesce(current_setting('request.path', true), '');
begin
  if new.status is distinct from old.status
     and public.is_off_process_transition(old.status, new.status)
     and (v_path like '%/rpc/transition_mandate_status' or v_path ~ '(^|/)mandates$')
     and public.is_manager()
     and not public.is_supervisor() then
    raise exception 'Réservé au superviseur : la transition % → % sort du traitement normal du dossier',
      old.status, new.status using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists guard_off_process_transition on public.mandates;
create trigger guard_off_process_transition
  before update of status on public.mandates
  for each row execute function public.trg_guard_off_process_transition();

revoke all on function public.trg_guard_off_process_transition() from public, anon, authenticated;

-- 3. Listes d'experts : lecture pour l'organisation, écriture directe réservée au superviseur
--    (les fonctions save_expert_list, duplicate_expert_list, add_experts_to_lists contrôlent déjà le rôle).
drop policy if exists "org members manage their expert lists" on public.expert_lists;
create policy "org members read their expert lists" on public.expert_lists
  for select using (organization_id = public.current_user_organization_id());
create policy "supervisors write their expert lists" on public.expert_lists
  for all using (organization_id = public.current_user_organization_id() and public.is_supervisor())
  with check (organization_id = public.current_user_organization_id() and public.is_supervisor());

drop policy if exists "org members manage their expert list members" on public.expert_list_members;
create policy "org members read their expert list members" on public.expert_list_members
  for select using (exists (select 1 from public.expert_lists l
                             where l.id = expert_list_members.list_id
                               and l.organization_id = public.current_user_organization_id()));
create policy "supervisors write their expert list members" on public.expert_list_members
  for all using (public.is_supervisor() and exists (select 1 from public.expert_lists l
                             where l.id = expert_list_members.list_id
                               and l.organization_id = public.current_user_organization_id()))
  with check (public.is_supervisor() and exists (select 1 from public.expert_lists l
                             where l.id = expert_list_members.list_id
                               and l.organization_id = public.current_user_organization_id()));

-- 4. Le tableau de bord indique à l'application si l'utilisateur est superviseur
--    (affichage des boutons et menus réservés).
create or replace function public.dashboard_bundle()
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare v_sup jsonb := '[]'::jsonb;
begin
  begin
    v_sup := coalesce(public.supervision_dashboard(), '[]'::jsonb);
  exception when others then
    v_sup := '[]'::jsonb;
  end;
  return jsonb_build_object(
    'dashboard', public.manager_dashboard(),
    'supervision', v_sup,
    'is_supervisor', coalesce(public.is_supervisor(), false),
    'danger', case when jsonb_array_length(case when jsonb_typeof(v_sup) = 'array' then v_sup else '[]'::jsonb end) > 0
                   then public.danger_mandates_list() else '[]'::jsonb end);
end $function$;
