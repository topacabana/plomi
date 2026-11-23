-- Complétion des mandats importés sans rendez-vous (décidé le 23/11/2026).
-- Un import CSV peut contenir tout l'obligatoire (type, adresse, CP ou ville, nom, prénom, téléphone ou
-- e-mail) sans les créneaux : le mandat est importé « incomplet » et ne peut être ni diffusé ni attribué
-- tant qu'il n'a pas 3 créneaux. Depuis la fiche mandat, le gestionnaire envoie au client un lien
-- personnel (7 jours) vers une page PLOMI : 3 créneaux + informations manquantes, ou demande de rappel.

alter table public.mandates
  add column if not exists completion_status text not null default 'complete'
    check (completion_status in ('complete', 'incomplete', 'awaiting_client', 'callback_requested')),
  add column if not exists completion_requested_at timestamptz,
  add column if not exists completion_answered_at timestamptz,
  add column if not exists callback_phone text,
  add column if not exists callback_slot text,
  add column if not exists callback_note text;
comment on column public.mandates.completion_status is 'complete | incomplete (créneaux manquants) | awaiting_client (lien envoyé) | callback_requested (le client demande à être rappelé). Diffusion et attribution interdites tant que ≠ complete.';

create table if not exists public.mandate_completion_tokens (
  id          uuid primary key default gen_random_uuid(),
  mandate_id  uuid not null references public.mandates(id) on delete cascade,
  token_hash  text not null unique,
  sent_to     text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days',
  used_at     timestamptz
);
create index if not exists mandate_completion_tokens_mandate_idx on public.mandate_completion_tokens (mandate_id);
alter table public.mandate_completion_tokens enable row level security;
revoke all on public.mandate_completion_tokens from anon, authenticated;
comment on table public.mandate_completion_tokens is 'Liens de complétion envoyés aux clients (seul le hash SHA-256 du jeton est gardé). Lecture et écriture par l''Edge Function mandate-completion (clé service).';

-- 1. Statut calculé : import sans 3 créneaux → incomplet ; 3 créneaux renseignés → complet.
create or replace function public.trg_mandate_completion()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
declare v_full boolean := new.slot_1_at is not null and new.slot_2_at is not null and new.slot_3_at is not null;
begin
  if tg_op = 'INSERT' then
    if new.import_id is not null and not v_full then new.completion_status := 'incomplete'; end if;
  elsif new.completion_status <> 'complete' and v_full then
    new.completion_status := 'complete';
    new.completion_answered_at := coalesce(new.completion_answered_at, now());
  end if;
  return new;
end $function$;
drop trigger if exists mandate_completion on public.mandates;
create trigger mandate_completion before insert or update of slot_1_at, slot_2_at, slot_3_at, completion_status on public.mandates
  for each row execute function public.trg_mandate_completion();

-- 2. Garde serveur : pas de diffusion ni d'attribution d'un mandat incomplet.
create or replace function public.trg_mandate_completion_guard()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
begin
  if new.status is distinct from old.status
     and old.status::text in ('draft', 'new', 'drop_pending')
     and new.status::text in ('dropped', 'redrop', 'assigned')
     and new.completion_status <> 'complete' then
    raise exception 'Mandat % incomplet : 3 créneaux sont nécessaires avant de le diffuser ou de l''attribuer. Complétez-le ou demandez les informations au client depuis la fiche mandat.', coalesce(new.reference, '');
  end if;
  return new;
end $function$;
drop trigger if exists mandate_completion_guard on public.mandates;
create trigger mandate_completion_guard before update of status on public.mandates
  for each row execute function public.trg_mandate_completion_guard();

-- 3. Champs facultatifs que le client peut compléter (seulement ceux qui sont vides).
create or replace function public.mandate_completion_missing(p_mandate_id uuid)
 returns jsonb
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select coalesce((select jsonb_agg(v.k order by v.o) from (values
      ('mobile_phone', 1, b.mobile_phone is null or btrim(b.mobile_phone) = ''),
      ('email', 2, b.email is null or btrim(b.email) = ''),
      ('address_line_2', 3, m.address_line_2 is null or btrim(m.address_line_2) = ''),
      ('floor', 4, m.floor is null or btrim(m.floor::text) = ''),
      ('entry_code', 5, m.entry_code is null or btrim(m.entry_code) = ''),
      ('residence_type', 6, m.residence_type is null or btrim(m.residence_type::text) = ''),
      ('description', 7, m.description is null or btrim(m.description) = '')
    ) v(k, o, missing) where v.missing), '[]'::jsonb)
  from public.mandates m left join public.beneficiaries b on b.id = m.beneficiary_id
  where m.id = p_mandate_id;
$function$;
revoke all on function public.mandate_completion_missing(uuid) from public, anon, authenticated;

-- 4. Gestionnaire : préparer une demande (appelée par l'Edge Function avec le jeton du gestionnaire).
--    Renvoie le jeton en clair UNE fois (seul son hash est gardé) et de quoi rédiger l'e-mail.
create or replace function public.manager_completion_prepare(p_mandate_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare v_m public.mandates%rowtype; v_b public.beneficiaries%rowtype; v_token text; v_org text; v_ins text;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select * into v_m from public.mandates where id = p_mandate_id and insurance_org_id = public.current_user_organization_id() for update;
  if not found then raise exception 'Mandat introuvable dans votre organisation'; end if;
  if v_m.completion_status = 'complete' then raise exception 'Ce mandat est déjà complet'; end if;
  if v_m.status::text not in ('draft', 'new', 'drop_pending') then raise exception 'Le mandat n''est plus en attente de diffusion'; end if;
  select * into v_b from public.beneficiaries where id = v_m.beneficiary_id;
  if v_b.email is null or btrim(v_b.email) = '' then
    raise exception 'Le bénéficiaire n''a pas d''adresse e-mail : complétez le mandat par téléphone';
  end if;
  if exists (select 1 from public.mandate_completion_tokens where mandate_id = p_mandate_id and created_at > now() - interval '2 minutes') then
    raise exception 'Une demande vient d''être envoyée : patientez quelques minutes avant de la renvoyer';
  end if;
  v_token := translate(encode(gen_random_bytes(24), 'base64'), '+/=', '-_');
  update public.mandate_completion_tokens set expires_at = least(expires_at, now()) where mandate_id = p_mandate_id and used_at is null;
  insert into public.mandate_completion_tokens (mandate_id, token_hash, sent_to)
  values (p_mandate_id, encode(digest(v_token, 'sha256'), 'hex'), v_b.email);
  update public.mandates set completion_status = 'awaiting_client', completion_requested_at = now() where id = p_mandate_id;
  select name into v_org from public.organizations where id = v_m.insurance_org_id;
  select name into v_ins from public.insurers where id = v_m.insurer_id;
  return jsonb_build_object('token', v_token, 'email', v_b.email, 'first_name', v_b.first_name, 'last_name', v_b.last_name,
    'reference', v_m.reference, 'insurer_file_number', v_m.insurer_file_number,
    'organization', v_org, 'insurer', coalesce(v_ins, nullif(v_m.requester_company_name, '')),
    'address', concat_ws(', ', v_m.address_line_1, nullif(concat_ws(' ', v_m.postal_code, v_m.city), '')));
end $function$;
revoke all on function public.manager_completion_prepare(uuid) from public, anon;
grant execute on function public.manager_completion_prepare(uuid) to authenticated;

-- 5. Client : lire la demande (clé service uniquement, via l'Edge Function).
create or replace function public.completion_get(p_token text)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare v_t public.mandate_completion_tokens%rowtype; v_m public.mandates%rowtype; v_b public.beneficiaries%rowtype; v_org text; v_ins text;
begin
  select * into v_t from public.mandate_completion_tokens where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found then return jsonb_build_object('ok', false, 'error', 'Lien invalide'); end if;
  if v_t.used_at is not null then return jsonb_build_object('ok', false, 'error', 'Ce formulaire a déjà été envoyé. Merci, votre gestionnaire a bien reçu vos informations.', 'done', true); end if;
  if v_t.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'Ce lien a expiré. Contactez votre assureur ou l''agence pour en recevoir un nouveau.'); end if;
  select * into v_m from public.mandates where id = v_t.mandate_id;
  select * into v_b from public.beneficiaries where id = v_m.beneficiary_id;
  select name into v_org from public.organizations where id = v_m.insurance_org_id;
  select name into v_ins from public.insurers where id = v_m.insurer_id;
  return jsonb_build_object('ok', true, 'reference', v_m.reference, 'insurer_file_number', v_m.insurer_file_number,
    'first_name', v_b.first_name, 'organization', v_org, 'insurer', coalesce(v_ins, nullif(v_m.requester_company_name, '')),
    'address', concat_ws(', ', v_m.address_line_1, nullif(concat_ws(' ', v_m.postal_code, v_m.city), '')),
    'sinister', array_to_string(v_m.sinister_type, ', '),
    'missing', public.mandate_completion_missing(v_m.id),
    'phone', coalesce(v_b.mobile_phone, v_b.landline_phone),
    'expires_at', v_t.expires_at);
end $function$;
revoke all on function public.completion_get(text) from public, anon, authenticated;
grant execute on function public.completion_get(text) to service_role;

-- 6. Client : enregistrer la réponse (clé service uniquement). Mode « slots » : 3 créneaux distincts, dans le futur,
--    à moins de 3 mois, entre 7 h et 20 h (heure de Paris) ; mode « callback » : demande de rappel.
create or replace function public.completion_submit(p_token text, p_payload jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_t public.mandate_completion_tokens%rowtype; v_m public.mandates%rowtype;
  v_mode text := coalesce(p_payload->>'mode', 'slots');
  v_s timestamptz[]; v_x timestamptz; v_h int; v_missing jsonb; v_val text; k text; v_phone text;
begin
  select * into v_t from public.mandate_completion_tokens
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Lien invalide'); end if;
  if v_t.used_at is not null then return jsonb_build_object('ok', false, 'error', 'Ce formulaire a déjà été envoyé', 'done', true); end if;
  if v_t.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'Ce lien a expiré'); end if;
  select * into v_m from public.mandates where id = v_t.mandate_id for update;
  if v_m.status::text not in ('draft', 'new', 'drop_pending') then
    return jsonb_build_object('ok', false, 'error', 'Votre dossier est déjà pris en charge : vous serez contacté directement.');
  end if;

  if v_mode = 'callback' then
    v_phone := regexp_replace(coalesce(p_payload->>'callback_phone', ''), '[^\d+]', '', 'g');
    if v_phone !~ '^(\+33|0)[1-9]\d{8}$' then return jsonb_build_object('ok', false, 'error', 'Indiquez un numéro de téléphone valide pour être rappelé'); end if;
    update public.mandates set completion_status = 'callback_requested', completion_answered_at = now(),
           callback_phone = v_phone, callback_slot = left(nullif(btrim(coalesce(p_payload->>'callback_slot', '')), ''), 60),
           callback_note = left(nullif(btrim(coalesce(p_payload->>'callback_note', '')), ''), 500)
     where id = v_m.id;
    update public.mandate_completion_tokens set used_at = now() where id = v_t.id;
    perform public.notify_managers(v_m.insurance_org_id, 'system', v_m.reference || ' : rappel demandé par le client',
      'Le client souhaite être rappelé au ' || v_phone || coalesce(' (' || nullif(p_payload->>'callback_slot', '') || ')', '')
        || '. Complétez le mandat par téléphone depuis la Liste de drop.',
      v_m.id, 'mandate', v_m.id, 'drop_pending', null);
    return jsonb_build_object('ok', true, 'mode', 'callback');
  end if;

  begin
    select array_agg(x::timestamptz order by x::timestamptz) into v_s
      from jsonb_array_elements_text(coalesce(p_payload->'slots', '[]'::jsonb)) x where btrim(x) <> '';
  exception when others then return jsonb_build_object('ok', false, 'error', 'Créneaux illisibles');
  end;
  if coalesce(cardinality(v_s), 0) <> 3 then return jsonb_build_object('ok', false, 'error', 'Proposez 3 créneaux'); end if;
  if (select count(distinct date_trunc('hour', s)) from unnest(v_s) s) < 3 then return jsonb_build_object('ok', false, 'error', 'Les 3 créneaux doivent être différents'); end if;
  foreach v_x in array v_s loop
    if v_x < now() + interval '12 hours' then return jsonb_build_object('ok', false, 'error', 'Chaque créneau doit être au moins 12 heures à l''avance'); end if;
    if v_x > now() + interval '3 months' then return jsonb_build_object('ok', false, 'error', 'Les créneaux doivent être dans les 3 prochains mois'); end if;
    v_h := extract(hour from v_x at time zone 'Europe/Paris');
    if v_h < 7 or v_h >= 20 then return jsonb_build_object('ok', false, 'error', 'Les créneaux doivent être entre 7 h et 20 h'); end if;
  end loop;

  -- Informations complémentaires : uniquement les champs qui étaient vides
  v_missing := public.mandate_completion_missing(v_m.id);
  for k in select jsonb_array_elements_text(v_missing) loop
    v_val := left(nullif(btrim(coalesce(p_payload#>>array['fields', k], '')), ''), 500);
    continue when v_val is null;
    if k = 'email' then
      if v_val !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'Adresse e-mail invalide'); end if;
      update public.beneficiaries set email = lower(v_val) where id = v_m.beneficiary_id;
    elsif k = 'mobile_phone' then
      v_val := regexp_replace(v_val, '[^\d+]', '', 'g');
      if v_val !~ '^(\+33|0)[1-9]\d{8}$' then return jsonb_build_object('ok', false, 'error', 'Numéro de téléphone invalide'); end if;
      update public.beneficiaries set mobile_phone = v_val where id = v_m.beneficiary_id;
    elsif k = 'address_line_2' then update public.mandates set address_line_2 = v_val where id = v_m.id;
    elsif k = 'floor' then update public.mandates set floor = left(v_val, 20) where id = v_m.id;
    elsif k = 'entry_code' then update public.mandates set entry_code = left(v_val, 40) where id = v_m.id;
    elsif k = 'residence_type' then update public.mandates set residence_type = left(v_val, 60) where id = v_m.id;
    elsif k = 'description' then update public.mandates set description = v_val where id = v_m.id;
    end if;
  end loop;

  update public.mandates set slot_1_at = v_s[1], slot_2_at = v_s[2], slot_3_at = v_s[3], completion_answered_at = now() where id = v_m.id;
  update public.mandate_completion_tokens set used_at = now() where id = v_t.id;
  perform public.notify_managers(v_m.insurance_org_id, 'system', v_m.reference || ' : complété par le client',
    'Le client a proposé 3 créneaux' || case when jsonb_array_length(v_missing) > 0 then ' et complété son dossier' else '' end
      || '. Le mandat est prêt à être diffusé depuis la Liste de drop.',
    v_m.id, 'mandate', v_m.id, 'drop_pending', null);
  return jsonb_build_object('ok', true, 'mode', 'slots');
end $function$;
revoke all on function public.completion_submit(text, jsonb) from public, anon, authenticated;
grant execute on function public.completion_submit(text, jsonb) to service_role;

-- 7. Logos + état de complétion des mandats pour les listes gestionnaire (variable mandateLogos).
create or replace function public.manager_mandate_logos()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return coalesce((
    select jsonb_object_agg(m.id, jsonb_build_object(
             'logo', coalesce(i.logo_url, nullif(m.requester_logo_url, '')),
             'name', coalesce(i.name, nullif(m.requester_company_name, ''), 'Particulier'),
             'completion', m.completion_status,
             'has_email', coalesce(nullif(btrim(b.email), ''), '') <> '',
             'callback', case when m.completion_status = 'callback_requested'
                              then concat_ws(' · ', m.callback_phone, m.callback_slot) end,
             'requested_at', m.completion_requested_at))
      from public.mandates m
      left join public.insurers i on i.id = m.insurer_id
      left join public.beneficiaries b on b.id = m.beneficiary_id
     where m.insurance_org_id = v_org), '{}'::jsonb);
end $function$;

-- 8. Les mandats importés en attente sans 3 créneaux deviennent incomplets.
update public.mandates set completion_status = 'incomplete'
 where import_id is not null and status::text in ('draft', 'new', 'drop_pending')
   and (slot_1_at is null or slot_2_at is null or slot_3_at is null);
