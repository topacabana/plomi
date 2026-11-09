-- PLOMI — Géocodage Google (adresse -> latitude / longitude) pour les mandats et les experts.
-- Les coordonnées vides ou à 0,0 sont recalculées par l'Edge Function geocode-addresses
-- (clé Google du coffre Vault), appelée à chaque nouvelle adresse et toutes les 15 min.

alter table public.mandates
  add column if not exists geocoded_at timestamptz,
  add column if not exists geocode_error text;
alter table public.experts
  add column if not exists geocoded_at timestamptz,
  add column if not exists geocode_error text;

-- 0,0 = pas de coordonnées
update public.mandates set latitude = null, longitude = null where coalesce(latitude,0) = 0 or coalesce(longitude,0) = 0;
update public.experts  set latitude = null, longitude = null where coalesce(latitude,0) = 0 or coalesce(longitude,0) = 0;

-- Adresse modifiée sans nouvelles coordonnées : on efface les anciennes pour forcer le recalcul
create or replace function public.trg_geocode_reset()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if (new.address_line_1, new.postal_code, new.city) is distinct from (old.address_line_1, old.postal_code, old.city)
     and new.latitude is not distinct from old.latitude and new.longitude is not distinct from old.longitude then
    new.latitude := null; new.longitude := null; new.geocoded_at := null; new.geocode_error := null;
  end if;
  if coalesce(new.latitude,0) = 0 or coalesce(new.longitude,0) = 0 then
    new.latitude := null; new.longitude := null;
  end if;
  return new;
end $$;

drop trigger if exists mandates_geocode_reset on public.mandates;
create trigger mandates_geocode_reset before update of address_line_1, postal_code, city, latitude, longitude on public.mandates
  for each row execute function public.trg_geocode_reset();
drop trigger if exists experts_geocode_reset on public.experts;
create trigger experts_geocode_reset before update of address_line_1, postal_code, city, latitude, longitude on public.experts
  for each row execute function public.trg_geocode_reset();

-- Lecture des adresses à géocoder + clé Google (réservé au service, jeton Vault obligatoire)
create or replace function public.geocode_pending(p_token text, p_limit integer default 25)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  return jsonb_build_object(
    'key', (select decrypted_secret from vault.decrypted_secrets where name = 'google_maps_key'),
    'items', coalesce((
      select jsonb_agg(x) from (
        (select 'mandate' as kind, m.id,
                concat_ws(', ', nullif(trim(m.address_line_1),''), nullif(trim(concat_ws(' ', m.postal_code, m.city)),''), 'France') as address
           from public.mandates m
          where m.latitude is null and nullif(trim(coalesce(m.address_line_1,'') || coalesce(m.city,'') || coalesce(m.postal_code,'')),'') is not null
            and (m.geocode_error is null or m.geocoded_at < now() - interval '1 day')
          order by m.created_at desc limit p_limit)
        union all
        (select 'expert', e.id,
                concat_ws(', ', nullif(trim(e.address_line_1),''), nullif(trim(concat_ws(' ', e.postal_code, e.city)),''), 'France')
           from public.experts e
          where e.latitude is null and nullif(trim(coalesce(e.address_line_1,'') || coalesce(e.city,'') || coalesce(e.postal_code,'')),'') is not null
            and (e.geocode_error is null or e.geocoded_at < now() - interval '1 day')
          limit p_limit)
      ) x), '[]'::jsonb));
end $$;

create or replace function public.geocode_save(p_token text, p_kind text, p_id uuid, p_lat numeric, p_lng numeric, p_error text default null)
 returns void language plpgsql security definer set search_path to 'public'
as $$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  if p_kind = 'mandate' then
    update public.mandates set latitude = p_lat, longitude = p_lng, geocoded_at = now(), geocode_error = p_error where id = p_id;
  elsif p_kind = 'expert' then
    update public.experts set latitude = p_lat, longitude = p_lng, geocoded_at = now(), geocode_error = p_error where id = p_id;
  else
    raise exception 'Type inconnu';
  end if;
end $$;

revoke execute on function public.geocode_pending(text, integer) from public, anon, authenticated;
revoke execute on function public.geocode_save(text, text, uuid, numeric, numeric, text) from public, anon, authenticated;
revoke execute on function public.trg_geocode_reset() from public, anon, authenticated;
grant execute on function public.geocode_pending(text, integer) to service_role;
grant execute on function public.geocode_save(text, text, uuid, numeric, numeric, text) to service_role;

-- Appel immédiat (asynchrone, pg_net) quand une adresse attend ses coordonnées
create or replace function public.trg_geocode_kick()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if new.latitude is null and nullif(trim(coalesce(new.address_line_1,'') || coalesce(new.city,'')),'') is not null then
    perform net.http_post(
      url := 'https://ybbzfedbdjgcahqajltm.supabase.co/functions/v1/geocode-addresses',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object('token', (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token')),
      timeout_milliseconds := 30000);
  end if;
  return null;
end $$;
revoke execute on function public.trg_geocode_kick() from public, anon, authenticated;

drop trigger if exists mandates_geocode_kick on public.mandates;
create trigger mandates_geocode_kick after insert or update of address_line_1, postal_code, city on public.mandates
  for each row execute function public.trg_geocode_kick();
drop trigger if exists experts_geocode_kick on public.experts;
create trigger experts_geocode_kick after insert or update of address_line_1, postal_code, city on public.experts
  for each row execute function public.trg_geocode_kick();

-- Filet de sécurité : toutes les 15 minutes
select cron.schedule('geocode_addresses', '*/15 * * * *', $c$
  select net.http_post(
    url := 'https://ybbzfedbdjgcahqajltm.supabase.co/functions/v1/geocode-addresses',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('token', (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token')),
    timeout_milliseconds := 60000)
$c$) where not exists (select 1 from cron.job where jobname = 'geocode_addresses');
