-- Création de mandat : organisme demandeur obligatoire.
-- Trois cas exclusifs :
--   insurer     : un assureur de l'organisation (mandates.insurer_id) ;
--   third_party : une entreprise tierce (raison sociale, dénomination, SIRET, contact, logo) ;
--   individual  : la demande vient d'un particulier.
-- La règle est contrôlée côté serveur dans save_mandate_form (le front ne fait qu'afficher).

alter table public.mandates
  add column if not exists requester_type text,
  add column if not exists requester_company_name text,
  add column if not exists requester_trade_name text,
  add column if not exists requester_siret text,
  add column if not exists requester_contact_first_name text,
  add column if not exists requester_contact_last_name text,
  add column if not exists requester_contact_phone text,
  add column if not exists requester_contact_email text,
  add column if not exists requester_logo_url text;

alter table public.mandates drop constraint if exists mandates_requester_type_check;
alter table public.mandates add constraint mandates_requester_type_check
  check (requester_type is null or requester_type in ('insurer', 'third_party', 'individual'));

alter table public.mandates drop constraint if exists mandates_requester_siret_check;
alter table public.mandates add constraint mandates_requester_siret_check
  check (requester_siret is null or requester_siret ~ '^\d{14}$');

comment on column public.mandates.requester_type is 'Organisme demandeur : insurer (insurer_id), third_party (champs requester_*), individual (particulier)';

-- Les mandats déjà rattachés à un assureur (imports, saisies) sont des demandes d'assureur.
update public.mandates set requester_type = 'insurer'
 where requester_type is null and insurer_id is not null;

-- save_mandate_form : nouveaux champs éditables + contrôle du demandeur.
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.save_mandate_form(uuid, jsonb, boolean, uuid[], boolean)'::regprocedure);

  if position('''insurer_id'',''import_id'',''insurer_file_number''];' in d) = 0
     or position('  if cardinality(coalesce(p_list_ids, ''{}'')) > 0 then' in d) = 0 then
    raise exception 'save_mandate_form : points d''insertion introuvables';
  end if;

  d := replace(d, '''insurer_id'',''import_id'',''insurer_file_number''];',
    '''insurer_id'',''import_id'',''insurer_file_number'',
    ''requester_type'',''requester_company_name'',''requester_trade_name'',''requester_siret'',
    ''requester_contact_first_name'',''requester_contact_last_name'',''requester_contact_phone'',
    ''requester_contact_email'',''requester_logo_url''];');

  d := replace(d, '  if cardinality(coalesce(p_list_ids, ''{}'')) > 0 then',
$r$  -- Organisme demandeur : obligatoire et exclusif.
  perform public.check_mandate_requester(v_id);

  if cardinality(coalesce(p_list_ids, '{}')) > 0 then$r$);

  execute d;
end
$mig$;

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
    update public.mandates set insurer_id = null where id = p_mandate_id;

  else -- individual
    update public.mandates set insurer_id = null, requester_company_name = null, requester_trade_name = null, requester_siret = null,
           requester_contact_first_name = null, requester_contact_last_name = null, requester_contact_phone = null,
           requester_contact_email = null, requester_logo_url = null
     where id = p_mandate_id;
  end if;
end $$;

revoke all on function public.check_mandate_requester(uuid) from public, anon, authenticated;
