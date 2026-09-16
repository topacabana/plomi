-- expert_profiles est une table de reference (code/label/icon/color), meme nature que
-- appliance_types, defect_types, mandate_types... qui ont toutes une lecture publique.
-- Oubli corrige ici avec exactement le meme pattern.
create policy "Allow public read expert_profiles"
  on public.expert_profiles
  for select
  to anon, authenticated
  using (true);

-- expert_profile_assignments est une table de liaison (donnees reelles), meme nature que
-- mandate_assignments : un gestionnaire gere les assignations des experts de sa propre
-- organisation, un expert lit ses propres assignations.
create policy "org manages profile assignments of its experts"
  on public.expert_profile_assignments
  for all
  using (
    current_user_role() = 'gestionnaire_assurance'::app_role
    and exists (
      select 1 from public.experts e
      where e.id = expert_profile_assignments.expert_id
        and e.organization_id = current_user_organization_id()
    )
  )
  with check (
    current_user_role() = 'gestionnaire_assurance'::app_role
    and exists (
      select 1 from public.experts e
      where e.id = expert_profile_assignments.expert_id
        and e.organization_id = current_user_organization_id()
    )
  );

create policy "expert read own profile assignments"
  on public.expert_profile_assignments
  for select
  using (
    current_user_role() = 'expert'::app_role
    and exists (
      select 1 from public.experts e
      where e.id = expert_profile_assignments.expert_id
        and e.user_id = auth.uid()
    )
  );
