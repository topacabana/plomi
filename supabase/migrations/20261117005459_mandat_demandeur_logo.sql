-- Logo de l'entreprise tierce : image PNG/JPG/WebP/SVG (URL https ou data URI base64), 1 Mo maximum.
-- Le front WeWeb lit l'image nativement (ww-input-file, base64) sans code JavaScript.

create or replace function public.check_mandate_requester(p_mandate_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare m public.mandates;
begin
  select * into m from public.mandates where id = p_mandate_id;

  if m.requester_type is null then
    raise exception 'Organisme demandeur obligatoire : choisissez un assureur, renseignez l''entreprise tierce ou cochez « À la demande d''un particulier »';
  end if;

  if m.requester_type = 'insurer' then
    if m.insurer_id is null then
      raise exception 'Organisme demandeur : sélectionnez l''assureur';
    end if;
    update public.mandates set requester_company_name = null, requester_trade_name = null, requester_siret = null,
           requester_contact_first_name = null, requester_contact_last_name = null, requester_contact_phone = null,
           requester_contact_email = null, requester_logo_url = null
     where id = p_mandate_id;

  elsif m.requester_type = 'third_party' then
    if nullif(trim(m.requester_company_name), '') is null then raise exception 'Entreprise tierce : la raison sociale est obligatoire'; end if;
    if nullif(trim(m.requester_trade_name), '') is null then raise exception 'Entreprise tierce : la dénomination est obligatoire'; end if;
    if m.requester_siret is null then raise exception 'Entreprise tierce : le numéro de SIRET (14 chiffres) est obligatoire'; end if;
    if nullif(trim(m.requester_contact_last_name), '') is null or nullif(trim(m.requester_contact_first_name), '') is null then
      raise exception 'Entreprise tierce : le nom et le prénom du contact sont obligatoires';
    end if;
    if nullif(trim(m.requester_contact_phone), '') is null then raise exception 'Entreprise tierce : le téléphone du contact est obligatoire'; end if;
    if coalesce(m.requester_contact_email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'Entreprise tierce : l''e-mail du contact est obligatoire et doit être valide';
    end if;
    if nullif(trim(m.requester_logo_url), '') is null then raise exception 'Entreprise tierce : le logo est obligatoire'; end if;
    -- Logo : URL https ou image encodée (data:image/...), 1 Mo maximum une fois encodé (~1,4 million de caractères).
    if m.requester_logo_url !~ '^(https://|data:image/(png|jpeg|webp|svg\+xml);base64,)' then
      raise exception 'Entreprise tierce : le logo doit être une image PNG, JPG, WebP ou SVG';
    end if;
    if length(m.requester_logo_url) > 1400000 then raise exception 'Entreprise tierce : logo trop lourd (1 Mo maximum)'; end if;
    update public.mandates set insurer_id = null where id = p_mandate_id;

  else -- individual
    update public.mandates set insurer_id = null, requester_company_name = null, requester_trade_name = null, requester_siret = null,
           requester_contact_first_name = null, requester_contact_last_name = null, requester_contact_phone = null,
           requester_contact_email = null, requester_logo_url = null
     where id = p_mandate_id;
  end if;
end $$;

revoke all on function public.check_mandate_requester(uuid) from public, anon, authenticated;
