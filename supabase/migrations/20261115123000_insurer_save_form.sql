-- Fiche assureur : enregistrement « no-code ».
-- Une fonction à paramètres nommés (un par champ du formulaire) que WeWeb appelle avec l'action native
-- « Call Postgres function », sans JavaScript. Les contrôles de saisie sont faits ici, côté serveur
-- (on ne se fie jamais au navigateur), et la fonction renvoie un résultat lisible plutôt qu'une
-- exception : { ok, error, id, created, detail }.
create or replace function public.insurer_save_form(
  p_id uuid default null,
  p_name text default null,
  p_address_line_1 text default null,
  p_postal_code text default null,
  p_city text default null,
  p_catchment_city text default null,
  p_catchment_radius_km text default null,
  p_contact_name text default null,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_notes text default null,
  p_logo_url text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_radius text := nullif(btrim(p_catchment_radius_km), '');
  v_email text := nullif(btrim(p_contact_email), '');
  v_id uuid;
begin
  -- Contrôles de saisie (messages affichés tels quels sous le formulaire)
  if nullif(btrim(p_name), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Le nom de l''assureur est obligatoire.');
  end if;
  if nullif(btrim(p_catchment_city), '') is not null and v_radius is null then
    return jsonb_build_object('ok', false, 'error', 'Indiquez le rayon de la zone de chalandise (en km).');
  end if;
  if v_radius is not null and (v_radius !~ '^\d+([.,]\d+)?$' or replace(v_radius, ',', '.')::numeric not between 1 and 1000) then
    return jsonb_build_object('ok', false, 'error', 'Le rayon doit être compris entre 1 et 1000 km.');
  end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'error', 'L''email du contact n''est pas valide.');
  end if;

  -- Enregistrement (droits, unicité du nom et géocodage gérés par insurer_save)
  begin
    v_id := public.insurer_save(p_id, jsonb_build_object(
      'name', p_name, 'address_line_1', p_address_line_1, 'postal_code', p_postal_code, 'city', p_city,
      'catchment_city', p_catchment_city, 'catchment_radius_km', replace(coalesce(v_radius, ''), ',', '.'),
      'contact_name', p_contact_name, 'contact_email', v_email, 'contact_phone', p_contact_phone,
      'notes', p_notes, 'logo_url', p_logo_url));
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;

  return jsonb_build_object('ok', true, 'id', v_id, 'created', p_id is null,
                            'detail', public.insurer_detail(v_id));
end $$;

revoke execute on function public.insurer_save_form(uuid, text, text, text, text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.insurer_save_form(uuid, text, text, text, text, text, text, text, text, text, text, text) to authenticated, service_role;
