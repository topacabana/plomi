-- Temps réel : le front est prévenu de chaque prise / prolongation / libération de verrou
-- (RLS « read locks » s'applique aux abonnés).
do $$ begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'mandate_locks') then
    alter publication supabase_realtime add table public.mandate_locks;
  end if;
end $$;
