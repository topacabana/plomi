-- Sécurité étape 1 : RLS sur mandates
-- "Est un expert" = le compte a une fiche experts (validé : compte à double rôle)
create or replace function public.is_expert()
 returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.current_expert_id() is not null $$;

-- Évite la récursion mandates <-> mandate_assignments
create or replace function public.expert_has_assignment(p_mandate_id uuid)
 returns boolean language sql stable security definer set search_path to 'public'
as $$ select exists (select 1 from public.mandate_assignments
                      where mandate_id = p_mandate_id and expert_id = public.current_expert_id()) $$;

grant execute on function public.is_expert(), public.expert_has_assignment(uuid) to authenticated;

alter table public.mandates enable row level security;

drop policy if exists "gestionnaire : mandats de son organisation" on public.mandates;
create policy "gestionnaire : mandats de son organisation" on public.mandates
  for all to authenticated
  using (public.is_manager() and insurance_org_id = public.current_user_organization_id())
  with check (public.is_manager() and insurance_org_id = public.current_user_organization_id());

drop policy if exists "expert : mandats sur la carte ou attribués" on public.mandates;
create policy "expert : mandats sur la carte ou attribués" on public.mandates
  for select to authenticated
  using (public.is_expert() and (
          assigned_expert_id = public.current_expert_id()
       or public.expert_has_assignment(id)
       or (visible_on_map and (coalesce(cardinality(target_list_ids), 0) = 0
                               or public.current_expert_matching_list(target_list_ids) is not null))));
