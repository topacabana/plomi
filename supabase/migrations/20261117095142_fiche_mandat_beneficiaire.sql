-- Fiche mandat (Détails_mandats) : coordonnées du bénéficiaire d'un mandat.
-- Remplace la lecture directe de la table beneficiaries depuis le JavaScript WeWeb.
-- security invoker : les règles RLS de mandates et de beneficiaries s'appliquent
-- (gestionnaire : son organisation ; expert : ses mandats attribués).

create or replace function public.mandate_beneficiary_contact(p_mandate_id uuid)
returns jsonb language sql stable security invoker set search_path = public as $$
  select coalesce((
    select jsonb_build_object(
      'first_name', b.first_name, 'last_name', b.last_name,
      'mobile_phone', b.mobile_phone, 'landline_phone', b.landline_phone, 'email', b.email)
    from mandates m
    join beneficiaries b on b.id = m.beneficiary_id
    where m.id = p_mandate_id
  ), '{}'::jsonb)
$$;

revoke all on function public.mandate_beneficiary_contact(uuid) from public, anon;
grant execute on function public.mandate_beneficiary_contact(uuid) to authenticated;
