create extension if not exists pg_net with schema extensions;

alter table public.mandates
  add column if not exists travel_time_min integer,
  add column if not exists travel_distance_km numeric(7,1),
  add column if not exists travel_expert_id uuid,
  add column if not exists travel_computed_at timestamptz,
  add column if not exists travel_error text;

do $$ begin
  if not exists (select 1 from vault.secrets where name = 'google_maps_key') then
    perform vault.create_secret('<GOOGLE_MAPS_API_KEY>', 'google_maps_key', 'Clé Google Maps (Distance Matrix) pour le temps de déplacement');
  end if;
  if not exists (select 1 from vault.secrets where name = 'travel_cron_token') then
    perform vault.create_secret(encode(gen_random_bytes(24), 'hex'), 'travel_cron_token', 'Jeton de la tâche planifiée travel-times');
  end if;
end $$;

-- Mandats à calculer (appelée par l'Edge Function avec la clé service, jeton vérifié)
create or replace function public.travel_pending(p_token text, p_limit int default 25)
 returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  return jsonb_build_object(
    'key', (select decrypted_secret from vault.decrypted_secrets where name = 'google_maps_key'),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'from', x.latitude || ',' || x.longitude, 'to', m.latitude || ',' || m.longitude, 'expert_id', x.id))
      from (select m.* from public.mandates m
             where m.assigned_expert_id is not null and m.latitude is not null and m.longitude is not null
               and (m.travel_expert_id is distinct from m.assigned_expert_id)
             order by m.assigned_at desc nulls last limit p_limit) m
      join public.experts x on x.id = m.assigned_expert_id and x.latitude is not null and x.longitude is not null), '[]'::jsonb));
end $$;

create or replace function public.travel_save(p_token text, p_mandate_id uuid, p_expert_id uuid, p_minutes integer, p_km numeric, p_error text default null)
 returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  update public.mandates set travel_time_min = p_minutes, travel_distance_km = p_km, travel_expert_id = p_expert_id,
         travel_computed_at = now(), travel_error = p_error
   where id = p_mandate_id;
end $$;
revoke all on function public.travel_pending(text, int) from public, anon, authenticated;
revoke all on function public.travel_save(text, uuid, uuid, integer, numeric, text) from public, anon, authenticated;
grant execute on function public.travel_pending(text, int) to service_role;
grant execute on function public.travel_save(text, uuid, uuid, integer, numeric, text) to service_role;
