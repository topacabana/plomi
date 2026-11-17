-- Rattrapage : geo_km a été créée en production par la première version de coverage_dashboard
-- (13/11/2026) mais n'apparaissait plus dans la migration du dépôt. Détecté par la CI
-- (rejeu des migrations sur une base vide). Définition identique à la production.
CREATE OR REPLACE FUNCTION public.geo_km(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select (6371 * 2 * asin(sqrt(
    power(sin(radians((lat2 - lat1)::float8) / 2), 2)
    + cos(radians(lat1::float8)) * cos(radians(lat2::float8)) * power(sin(radians((lng2 - lng1)::float8) / 2), 2)
  )))::numeric
$function$;
