-- Sécurité étape 5 : bucket documents privé
-- Lecture côté client limitée ; l'affichage passe par des liens signés (fonctions Edge).
drop policy if exists "rapports: lecture par utilisateurs connectes" on storage.objects;
drop policy if exists "rapports: remplacement par utilisateurs connectes" on storage.objects;
drop policy if exists "rapports: upload par utilisateurs connectes" on storage.objects;

create policy "documents : lecture (auteur, gestionnaire du mandat, ses exports)" on storage.objects
  for select to authenticated
  using (bucket_id = 'documents' and (
       ((storage.foldername(name))[1] = 'rapports' and (
            owner = auth.uid()
         or (public.is_manager() and exists (select 1 from public.mandates m
               where m.id::text = (storage.foldername(name))[2]
                 and m.insurance_org_id = public.current_user_organization_id()))))
    or ((storage.foldername(name))[1] = 'exports' and (storage.foldername(name))[2] = auth.uid()::text)));

create policy "documents : upload des photos de rapport par un expert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'documents' and (storage.foldername(name))[1] = 'rapports' and public.is_expert());

create policy "documents : remplacement de ses propres photos" on storage.objects
  for update to authenticated
  using (bucket_id = 'documents' and (storage.foldername(name))[1] = 'rapports' and owner = auth.uid())
  with check (bucket_id = 'documents' and (storage.foldername(name))[1] = 'rapports' and owner = auth.uid());

update storage.buckets set public = false where id = 'documents';
