-- Sécurité étape 3 : notifications, KPI experts, journal de performance
-- Notifications : règles "lecture / mise à jour de ses notifications" déjà présentes, on active la RLS.
alter table public.notifications enable row level security;

-- KPI : écrits uniquement par les fonctions de calcul (droits élevés)
alter table public.expert_kpis enable row level security;
create policy "gestionnaire : KPI des experts" on public.expert_kpis
  for select to authenticated using (public.is_manager());
create policy "expert : ses KPI" on public.expert_kpis
  for select to authenticated using (expert_id = public.current_expert_id());

-- Journal de performance : la condition "auth.jwt() ? 'role'" était toujours vraie
alter policy "Authenticated users can view logs" on public.expert_performance_logs
  using (public.is_manager() or expert_id = public.current_expert_id());
