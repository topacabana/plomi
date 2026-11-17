-- Géocodage : Google Geocoding remplacé par la Géoplateforme IGN (Base Adresse Nationale).
-- Gratuit, sans clé, hébergé en France : supprime un transfert hors UE (audit RGPD B5)
-- et la clé Google passée dans l'URL. Google ne sert plus qu'aux temps de trajet (Routes API).
-- Ajoute aussi les assureurs (adresse + ville centre de la zone de chalandise), jusqu'ici
-- géocodés dans le navigateur via api-adresse.data.gouv.fr, décommissionnée fin janvier 2026.

alter table public.insurers
  add column if not exists geocoded_at timestamptz,
  add column if not exists geocode_error text,
  add column if not exists catchment_geocoded_at timestamptz,
  add column if not exists catchment_geocode_error text;

-- File d'attente : plus de clé renvoyée ; chaque élément porte sa requête (q) et un type IGN facultatif.
create or replace function public.geocode_pending(p_token text, p_limit integer default 25)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(x) from (
      (select 'mandate' as kind, m.id, concat_ws(' ', nullif(trim(m.address_line_1), ''), m.postal_code, m.city) as q, null::text as type
         from mandates m
        where m.latitude is null and nullif(trim(concat(m.address_line_1, m.city, m.postal_code)), '') is not null
          and (m.geocode_error is null or m.geocoded_at < now() - interval '1 day')
        order by m.created_at desc limit p_limit)
      union all
      (select 'expert', e.id, concat_ws(' ', nullif(trim(e.address_line_1), ''), e.postal_code, e.city), null
         from experts e
        where e.latitude is null and nullif(trim(concat(e.address_line_1, e.city, e.postal_code)), '') is not null
          and (e.geocode_error is null or e.geocoded_at < now() - interval '1 day')
        limit p_limit)
      union all
      (select 'insurer', i.id, concat_ws(' ', nullif(trim(i.address_line_1), ''), i.postal_code, i.city), null
         from insurers i
        where i.archived_at is null and i.latitude is null and nullif(trim(concat(i.address_line_1, i.city, i.postal_code)), '') is not null
          and (i.geocode_error is null or i.geocoded_at < now() - interval '1 day')
        limit p_limit)
      union all
      (select 'insurer_zone', i.id, concat_ws(' ', i.catchment_city, i.catchment_postal_code), 'municipality'
         from insurers i
        where i.archived_at is null and i.catchment_latitude is null and nullif(trim(i.catchment_city), '') is not null
          and (i.catchment_geocode_error is null or i.catchment_geocoded_at < now() - interval '1 day')
        limit p_limit)
    ) x), '[]'::jsonb));
end $$;

-- Enregistrement d'un résultat (remplace geocode_save, conservée pour compatibilité).
create or replace function public.geocode_save_place(p_token text, p_kind text, p_id uuid,
  p_lat numeric, p_lng numeric, p_postcode text default null, p_error text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  if p_kind = 'mandate' then
    update mandates set latitude = p_lat, longitude = p_lng, geocoded_at = now(), geocode_error = p_error where id = p_id;
  elsif p_kind = 'expert' then
    update experts set latitude = p_lat, longitude = p_lng, geocoded_at = now(), geocode_error = p_error where id = p_id;
  elsif p_kind = 'insurer' then
    update insurers set latitude = p_lat, longitude = p_lng, geocoded_at = now(), geocode_error = p_error where id = p_id;
  elsif p_kind = 'insurer_zone' then
    update insurers set catchment_latitude = p_lat, catchment_longitude = p_lng,
           catchment_postal_code = coalesce(catchment_postal_code, p_postcode),
           catchment_geocoded_at = now(), catchment_geocode_error = p_error where id = p_id;
  else
    raise exception 'Type inconnu';
  end if;
end $$;

revoke execute on function public.geocode_pending(text, integer) from public, anon, authenticated;
revoke execute on function public.geocode_save_place(text, text, uuid, numeric, numeric, text, text) from public, anon, authenticated;
grant execute on function public.geocode_pending(text, integer) to service_role;
grant execute on function public.geocode_save_place(text, text, uuid, numeric, numeric, text, text) to service_role;
