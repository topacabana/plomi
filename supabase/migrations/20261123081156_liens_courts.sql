-- Liens courts vers les PDF du stockage privé (envoi par mail des archives expert).
-- Le lien signé Supabase fait plus de 300 caractères ; le lien court (…/functions/v1/l?c=<10 caractères>)
-- est résolu par l'Edge Function « l », qui fabrique à la volée un lien signé et redirige.
create table if not exists public.short_links (
  code        text primary key check (code ~ '^[A-Za-z0-9]{10}$'),
  bucket      text not null default 'documents',
  path        text not null,
  file_name   text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days'
);
create index if not exists short_links_expires_idx on public.short_links (expires_at);
alter table public.short_links enable row level security;
-- Aucune règle d'accès : seules les Edge Functions (clé service) lisent et écrivent la table.
revoke all on public.short_links from anon, authenticated;
comment on table public.short_links is 'Liens courts (7 jours) vers des fichiers du stockage privé, résolus par l''Edge Function l.';

-- Purge quotidienne des liens expirés, avec la purge existante si pg_cron est présent.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge_short_links';
    perform cron.schedule('purge_short_links', '17 3 * * *', $c$delete from public.short_links where expires_at < now() - interval '1 day'$c$);
  end if;
end $$;
