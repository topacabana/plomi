create policy "rapports: upload par utilisateurs connectes"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and (storage.foldername(name))[1] = 'rapports');
create policy "rapports: remplacement par utilisateurs connectes"
  on storage.objects for update to authenticated
  using (bucket_id = 'documents' and (storage.foldername(name))[1] = 'rapports')
  with check (bucket_id = 'documents' and (storage.foldername(name))[1] = 'rapports');
create policy "rapports: lecture par utilisateurs connectes"
  on storage.objects for select to authenticated
  using (bucket_id = 'documents' and (storage.foldername(name))[1] = 'rapports');
