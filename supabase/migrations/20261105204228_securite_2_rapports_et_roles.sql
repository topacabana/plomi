drop policy if exists "Allow all for testing" on public.rdf_reports;
drop policy if exists "gestionnaire : rapports de son organisation" on public.rdf_reports;
drop policy if exists "expert : ses rapports" on public.rdf_reports;
create policy "gestionnaire : rapports de son organisation" on public.rdf_reports
  for select to authenticated
  using (public.is_manager() and exists (
    select 1 from public.mandates m
     where m.id = rdf_reports.mandate_id and m.insurance_org_id = public.current_user_organization_id()));
create policy "expert : ses rapports" on public.rdf_reports
  for select to authenticated
  using (public.is_expert() and created_by = auth.uid());

drop policy if exists "rooms: lecture utilisateurs connectes" on public.rdf_report_rooms;
drop policy if exists "gestionnaire : pièces des rapports de son organisation" on public.rdf_report_rooms;
drop policy if exists "expert : pièces de ses rapports" on public.rdf_report_rooms;
create policy "gestionnaire : pièces des rapports de son organisation" on public.rdf_report_rooms
  for select to authenticated
  using (public.is_manager() and exists (
    select 1 from public.mandates m
     where m.id = rdf_report_rooms.mandate_id and m.insurance_org_id = public.current_user_organization_id()));
create policy "expert : pièces de ses rapports" on public.rdf_report_rooms
  for select to authenticated
  using (public.is_expert() and exists (
    select 1 from public.rdf_reports r where r.id = rdf_report_rooms.report_id and r.created_by = auth.uid()));

do $h$
declare p record; q text; c text; sql text;
begin
  for p in select schemaname, tablename, policyname, qual, with_check from pg_policies
            where schemaname = 'public'
              and (coalesce(qual,'') ~ 'current_user_role\(\)' or coalesce(with_check,'') ~ 'current_user_role\(\)') loop
    q := replace(replace(p.qual, '(current_user_role() = ''expert''::app_role)', 'is_expert()'),
                 '(current_user_role() = ''gestionnaire_assurance''::app_role)', 'is_manager()');
    c := replace(replace(p.with_check, '(current_user_role() = ''expert''::app_role)', 'is_expert()'),
                 '(current_user_role() = ''gestionnaire_assurance''::app_role)', 'is_manager()');
    sql := format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
    if q is not null then sql := sql || format(' using (%s)', q); end if;
    if c is not null then sql := sql || format(' with check (%s)', c); end if;
    execute sql;
  end loop;
end $h$;
