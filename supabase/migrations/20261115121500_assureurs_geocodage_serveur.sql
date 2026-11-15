-- Assureurs : le géocodage passe entièrement côté serveur (geocode-addresses, Géoplateforme IGN).
-- insurer_save ne dépend plus des coordonnées envoyées par le navigateur :
--  · coordonnées fournies → utilisées (compatibilité avec l'ancien formulaire) ;
--  · adresse inchangée → coordonnées existantes conservées ;
--  · adresse modifiée → coordonnées remises à zéro, puis géocodage immédiat par le trigger ci-dessous.
create or replace function public.insurer_save(p_id uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_id uuid := p_id;
  v_name text := nullif(btrim(p_data->>'name'), '');
  v_radius integer := nullif(p_data->>'catchment_radius_km', '')::numeric::integer;
  v_old insurers%rowtype;
  v_addr text[] := array[nullif(btrim(p_data->>'address_line_1'), ''), nullif(btrim(p_data->>'postal_code'), ''), nullif(btrim(p_data->>'city'), '')];
  v_zone text := nullif(btrim(p_data->>'catchment_city'), '');
  v_same_addr boolean; v_same_zone boolean;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if v_name is null then raise exception 'Le nom de l''assureur est obligatoire'; end if;
  if exists (select 1 from insurers where organization_id = v_org and lower(name) = lower(v_name)
             and archived_at is null and id is distinct from v_id) then
    raise exception 'Un assureur porte déjà ce nom';
  end if;

  if v_id is null then
    insert into insurers (organization_id, name) values (v_org, v_name) returning id into v_id;
  elsif not exists (select 1 from insurers where id = v_id and organization_id = v_org) then
    raise exception 'Assureur introuvable';
  end if;

  select * into v_old from insurers where id = v_id;
  v_same_addr := array[v_old.address_line_1, v_old.postal_code, v_old.city] is not distinct from v_addr;
  v_same_zone := v_old.catchment_city is not distinct from v_zone;

  update insurers set
    name = v_name,
    logo_url = nullif(btrim(p_data->>'logo_url'), ''),
    address_line_1 = v_addr[1], postal_code = v_addr[2], city = v_addr[3],
    latitude  = coalesce(nullif(p_data->>'latitude', '')::numeric,  case when v_same_addr then v_old.latitude end),
    longitude = coalesce(nullif(p_data->>'longitude', '')::numeric, case when v_same_addr then v_old.longitude end),
    geocode_error = case when v_same_addr then v_old.geocode_error end,
    catchment_city = v_zone,
    catchment_postal_code = coalesce(nullif(btrim(p_data->>'catchment_postal_code'), ''), case when v_same_zone then v_old.catchment_postal_code end),
    catchment_latitude  = coalesce(nullif(p_data->>'catchment_latitude', '')::numeric,  case when v_same_zone then v_old.catchment_latitude end),
    catchment_longitude = coalesce(nullif(p_data->>'catchment_longitude', '')::numeric, case when v_same_zone then v_old.catchment_longitude end),
    catchment_geocode_error = case when v_same_zone then v_old.catchment_geocode_error end,
    catchment_radius_km = v_radius,
    contact_name = nullif(btrim(p_data->>'contact_name'), ''),
    contact_email = nullif(btrim(p_data->>'contact_email'), ''),
    contact_phone = nullif(btrim(p_data->>'contact_phone'), ''),
    notes = nullif(btrim(p_data->>'notes'), ''),
    updated_at = now()
  where id = v_id;
  return v_id;
end $$;

-- Géocodage immédiat quand une adresse ou une ville centre d'assureur reste à localiser.
create or replace function public.trg_geocode_kick_insurer()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if (new.latitude is null and nullif(trim(concat(new.address_line_1, new.city, new.postal_code)), '') is not null)
     or (new.catchment_latitude is null and nullif(trim(new.catchment_city), '') is not null) then
    perform net.http_post(
      url := 'https://ybbzfedbdjgcahqajltm.supabase.co/functions/v1/geocode-addresses',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object('token', (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token')),
      timeout_milliseconds := 30000);
  end if;
  return null;
end $$;

create or replace trigger insurers_geocode_kick
  after insert or update of address_line_1, postal_code, city, catchment_city on public.insurers
  for each row execute function public.trg_geocode_kick_insurer();

revoke execute on function public.trg_geocode_kick_insurer() from public, anon, authenticated;
