-- Vérification de la présence de l'expert chez le bénéficiaire, avant le début du rapport.
--
-- Risque traité : une personne mal intentionnée se présente comme l'expert mandaté pour entrer
-- dans un logement sinistré ; ou un expert « complète » un dossier sans s'être déplacé.
--
-- Principe :
--   1. Sur place, l'expert demande un code (Edge Function presence-verification, action "request").
--      Le serveur tire un code à 6 chiffres et l'envoie par e-mail AU BÉNÉFICIAIRE, avec le nom de
--      l'expert et de sa société. Le code n'est jamais renvoyé à l'expert ni stocké en clair.
--   2. Le bénéficiaire donne le code à la personne présente, qui le saisit dans l'app
--      (action "verify"). Si le code est bon, le bénéficiaire reçoit un e-mail « Identité confirmée »
--      et l'heure de vérification devient l'heure d'arrivée réelle (KPI respect des créneaux).
--   3. Si le bénéficiaire n'a pas d'adresse e-mail, l'expert coche une décharge de responsabilité
--      (texte versionné, horodaté) ; les gestionnaires de l'organisation sont prévenus.
--   Garde-fous : code valable 30 min, usage unique, 5 essais (au-delà : blocage + alerte aux
--   gestionnaires), 3 envois maximum par mandat. Les visio-expertises ne sont pas concernées.
--
-- Mise en service progressive : le démarrage du rapport n'exige la vérification que lorsque le
-- réglage app_settings.presence_verification_required vaut true (à activer une fois l'écran WeWeb
-- publié), pour ne jamais bloquer l'app en production entre la base et l'interface.

-- 1. Réglages de l'application (interrupteurs de fonctionnalités)
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;   -- aucune règle : lecture par fonctions uniquement
comment on table public.app_settings is 'Réglages de l''application (interrupteurs de fonctionnalités). Lus par des fonctions SECURITY DEFINER ; aucun accès direct.';

insert into public.app_settings (key, value)
values ('presence_verification_required', 'false'::jsonb)
on conflict (key) do nothing;

create or replace function public.app_setting_bool(p_key text)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $$ select coalesce((select (value)::text::boolean from public.app_settings where key = p_key), false) $$;
revoke execute on function public.app_setting_bool(text) from public, anon;
grant execute on function public.app_setting_bool(text) to authenticated, service_role;

-- 2. Traces de vérification
alter table public.mandates
  add column if not exists presence_verified_at timestamptz,
  add column if not exists presence_method text;
alter table public.mandates drop constraint if exists mandates_presence_method_chk;
alter table public.mandates
  add constraint mandates_presence_method_chk check (presence_method is null or presence_method in ('email_code', 'decharge'));
comment on column public.mandates.presence_verified_at is 'Heure à laquelle la présence de l''expert chez le bénéficiaire a été vérifiée (code e-mail) ou déchargée.';
comment on column public.mandates.presence_method is 'email_code = code reçu par le bénéficiaire et saisi par l''expert ; decharge = bénéficiaire sans e-mail, décharge cochée par l''expert.';

create table if not exists public.presence_verifications (
  id                uuid primary key default gen_random_uuid(),
  mandate_id        uuid not null references public.mandates(id) on delete cascade,
  expert_id         uuid not null references public.experts(id) on delete cascade,
  method            text not null check (method in ('email_code', 'decharge')),
  sent_to           text,
  code_hash         text,
  send_count        int  not null default 0,
  attempts          int  not null default 0,
  last_sent_at      timestamptz,
  expires_at        timestamptz,
  verified_at       timestamptz,
  locked_at         timestamptz,
  discharge_text    text,
  discharge_version text,
  created_at        timestamptz not null default now(),
  unique (mandate_id, expert_id)
);
alter table public.presence_verifications enable row level security;   -- aucune règle : jamais lue directement (le hachage du code ne sort pas)
comment on table public.presence_verifications is 'Vérification de présence de l''expert (code envoyé au bénéficiaire ou décharge). Accès uniquement par fonctions.';

-- 3. Texte de la décharge (versionné, comme l'accord destructif)
create or replace function public.presence_discharge_text()
 returns jsonb
 language sql
 immutable
 set search_path to ''
as $$
  select jsonb_build_object(
    'version', '2026-11-20',
    'text',
    'Le bénéficiaire n''a pas d''adresse e-mail renseignée : l''identité de l''expert n''a pas pu lui être confirmée par code. '
    || 'J''atteste avoir informé le bénéficiaire que cette vérification n''a pas pu être réalisée et qu''il accepte, sous sa responsabilité, '
    || 'que j''accède à son logement pour l''expertise. PLOMI et l''assureur mandant ne pourront être tenus responsables de l''absence de cette vérification.'
  );
$$;

-- Code à 6 chiffres tiré par un générateur cryptographique
create or replace function public.presence_new_code()
 returns text
 language sql
 volatile
 set search_path to ''
as $$ select lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000))::text, 6, '0') $$;
revoke execute on function public.presence_new_code() from public, anon, authenticated;

create or replace function public.presence_code_hash(p_id uuid, p_code text)
 returns text
 language sql
 immutable
 set search_path to ''
as $$ select encode(extensions.digest(p_id::text || ':' || coalesce(p_code, ''), 'sha256'), 'hex') $$;
revoke execute on function public.presence_code_hash(uuid, text) from public, anon, authenticated;

-- 4. Émission du code (appelée par l'Edge Function avec la clé service, au nom de l'expert authentifié)
create or replace function public.presence_code_issue(p_user_id uuid, p_mandate_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_expert uuid; v_m public.mandates%rowtype; v_email text; v_pv public.presence_verifications%rowtype; v_code text;
begin
  select id into v_expert from public.experts where user_id = p_user_id limit 1;
  if v_expert is null then return jsonb_build_object('ok', false, 'error', 'Aucun profil expert trouvé pour cet utilisateur'); end if;
  select * into v_m from public.mandates where id = p_mandate_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Mandat introuvable'); end if;
  if v_m.assigned_expert_id is distinct from v_expert then return jsonb_build_object('ok', false, 'error', 'Ce mandat ne vous est pas attribué'); end if;
  if v_m.mandate_type::text = 'visio' then return jsonb_build_object('ok', false, 'error', 'Pas de vérification de présence pour une visio-expertise'); end if;
  if v_m.status::text <> 'assigned' then return jsonb_build_object('ok', false, 'error', 'Le code ne peut être demandé que pour un mandat attribué, avant le début du rapport'); end if;
  if v_m.presence_verified_at is not null then return jsonb_build_object('ok', false, 'error', 'Présence déjà vérifiée'); end if;

  select nullif(trim(b.email), '') into v_email from public.beneficiaries b where b.id = v_m.beneficiary_id;
  if v_email is null then return jsonb_build_object('ok', false, 'error', 'Le bénéficiaire n''a pas d''adresse e-mail : utilisez la décharge', 'no_email', true); end if;

  select * into v_pv from public.presence_verifications where mandate_id = p_mandate_id and expert_id = v_expert for update;
  if found and v_pv.locked_at is not null then return jsonb_build_object('ok', false, 'error', 'Vérification bloquée après trop d''essais : contactez votre gestionnaire', 'locked', true); end if;
  if found and v_pv.send_count >= 3 then return jsonb_build_object('ok', false, 'error', 'Nombre maximal d''envois atteint (3) : contactez votre gestionnaire'); end if;
  if found and v_pv.last_sent_at > now() - interval '60 seconds' then return jsonb_build_object('ok', false, 'error', 'Un code vient d''être envoyé : patientez une minute avant d''en redemander un'); end if;

  v_code := public.presence_new_code();
  if not found then
    insert into public.presence_verifications (mandate_id, expert_id, method) values (p_mandate_id, v_expert, 'email_code')
    returning * into v_pv;
  end if;
  update public.presence_verifications
     set method = 'email_code', sent_to = v_email, code_hash = public.presence_code_hash(v_pv.id, v_code),
         send_count = send_count + 1, attempts = 0, last_sent_at = now(), expires_at = now() + interval '30 minutes'
   where id = v_pv.id
   returning * into v_pv;

  insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
  values (v_expert, 'presence_code_sent', p_mandate_id, jsonb_build_object('send_count', v_pv.send_count));

  return jsonb_build_object(
    'ok', true, 'code', v_code, 'email', v_email, 'expires_at', v_pv.expires_at, 'send_count', v_pv.send_count,
    'reference', v_m.reference,
    'expert_name', public.expert_display_name(v_expert),
    'company', (select company_name from public.experts where id = v_expert),
    'organization', (select name from public.organizations where id = v_m.insurance_org_id),
    'beneficiary_first_name', (select first_name from public.beneficiaries where id = v_m.beneficiary_id));
end $function$;
revoke execute on function public.presence_code_issue(uuid, uuid) from public, anon, authenticated;
grant execute on function public.presence_code_issue(uuid, uuid) to service_role;

-- 5. Vérification du code (Edge Function, clé service). Renvoie ok:false au lieu de lever une
--    exception, pour que le compteur d'essais soit bien enregistré.
create or replace function public.presence_code_check(p_user_id uuid, p_mandate_id uuid, p_code text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_expert uuid; v_m public.mandates%rowtype; v_pv public.presence_verifications%rowtype; v_left int;
begin
  select id into v_expert from public.experts where user_id = p_user_id limit 1;
  if v_expert is null then return jsonb_build_object('ok', false, 'error', 'Aucun profil expert trouvé pour cet utilisateur'); end if;
  select * into v_m from public.mandates where id = p_mandate_id for update;
  if not found or v_m.assigned_expert_id is distinct from v_expert then return jsonb_build_object('ok', false, 'error', 'Ce mandat ne vous est pas attribué'); end if;
  if v_m.presence_verified_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;

  select * into v_pv from public.presence_verifications where mandate_id = p_mandate_id and expert_id = v_expert and method = 'email_code' for update;
  if not found or v_pv.code_hash is null then return jsonb_build_object('ok', false, 'error', 'Aucun code demandé pour ce mandat'); end if;
  if v_pv.locked_at is not null then return jsonb_build_object('ok', false, 'error', 'Vérification bloquée après trop d''essais : contactez votre gestionnaire', 'locked', true); end if;
  if v_pv.expires_at < now() then return jsonb_build_object('ok', false, 'error', 'Code expiré : demandez-en un nouveau', 'expired', true); end if;

  if regexp_replace(coalesce(p_code, ''), '\s', '', 'g') !~ '^\d{6}$'
     or public.presence_code_hash(v_pv.id, regexp_replace(p_code, '\s', '', 'g')) <> v_pv.code_hash then
    update public.presence_verifications set attempts = attempts + 1,
           locked_at = case when attempts + 1 >= 5 then now() end
     where id = v_pv.id returning * into v_pv;
    v_left := greatest(0, 5 - v_pv.attempts);
    if v_pv.locked_at is not null then
      perform public.notify_managers(v_m.insurance_org_id, 'system', v_m.reference || ' : vérification de présence bloquée',
        public.expert_display_name(v_expert) || ' a saisi 5 codes erronés. Contactez le bénéficiaire avant toute intervention.',
        v_m.id, 'mandate', v_m.id, 'mandate_details', null);
      insert into public.expert_performance_logs (expert_id, event_type, mandate_id) values (v_expert, 'presence_locked', p_mandate_id);
      return jsonb_build_object('ok', false, 'error', 'Code erroné. Vérification bloquée : le gestionnaire est prévenu', 'locked', true);
    end if;
    return jsonb_build_object('ok', false, 'error', 'Code erroné', 'attempts_left', v_left);
  end if;

  update public.presence_verifications set verified_at = now(), code_hash = null where id = v_pv.id;
  update public.mandates set presence_verified_at = now(), presence_method = 'email_code', arrived_at = now() where id = p_mandate_id;
  insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
  values (v_expert, 'presence_verified', p_mandate_id,
          jsonb_build_object('method', 'email_code', 'planned_at', coalesce(v_m.selected_slot_at, v_m.slot_1_at)));

  return jsonb_build_object('ok', true, 'email', v_pv.sent_to, 'reference', v_m.reference,
    'expert_name', public.expert_display_name(v_expert),
    'company', (select company_name from public.experts where id = v_expert),
    'organization', (select name from public.organizations where id = v_m.insurance_org_id),
    'beneficiary_first_name', (select first_name from public.beneficiaries where id = v_m.beneficiary_id));
end $function$;
revoke execute on function public.presence_code_check(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.presence_code_check(uuid, uuid, text) to service_role;

-- 6. Décharge (bénéficiaire sans e-mail), appelée directement par l'app expert
create or replace function public.expert_presence_discharge(p_mandate_id uuid, p_version text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v_txt jsonb := public.presence_discharge_text();
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  select * into v_m from public.mandates where id = p_mandate_id for update;
  if not found or v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
  if v_m.status::text <> 'assigned' then raise exception 'La décharge se coche avant le début du rapport'; end if;
  if v_m.presence_verified_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  if exists (select 1 from public.beneficiaries b where b.id = v_m.beneficiary_id and nullif(trim(b.email), '') is not null) then
    raise exception 'Le bénéficiaire a une adresse e-mail : vérifiez la présence avec le code';
  end if;
  if p_version is distinct from v_txt->>'version' then raise exception 'Texte de décharge obsolète : rechargez la page'; end if;

  insert into public.presence_verifications (mandate_id, expert_id, method, discharge_text, discharge_version, verified_at)
  values (p_mandate_id, v_expert, 'decharge', v_txt->>'text', v_txt->>'version', now())
  on conflict (mandate_id, expert_id) do update
     set method = 'decharge', discharge_text = excluded.discharge_text, discharge_version = excluded.discharge_version,
         verified_at = now(), code_hash = null;
  update public.mandates set presence_verified_at = now(), presence_method = 'decharge', arrived_at = now() where id = p_mandate_id;
  insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
  values (v_expert, 'presence_verified', p_mandate_id,
          jsonb_build_object('method', 'decharge', 'planned_at', coalesce(v_m.selected_slot_at, v_m.slot_1_at)));
  perform public.notify_managers(v_m.insurance_org_id, 'system', v_m.reference || ' : présence non vérifiée (décharge)',
    public.expert_display_name(v_expert) || ' a démarré sans vérification d''identité : le bénéficiaire n''a pas d''adresse e-mail.',
    v_m.id, 'mandate', v_m.id, 'mandate_details', null);
  return jsonb_build_object('ok', true, 'method', 'decharge');
end $function$;
revoke execute on function public.expert_presence_discharge(uuid, text) from public, anon;
grant execute on function public.expert_presence_discharge(uuid, text) to authenticated;

-- 7. État de la vérification pour l'écran Lancement mandat
create or replace function public.expert_presence_status(p_mandate_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v_email text; v_pv public.presence_verifications%rowtype;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  select * into v_m from public.mandates where id = p_mandate_id;
  if not found or v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
  select nullif(trim(b.email), '') into v_email from public.beneficiaries b where b.id = v_m.beneficiary_id;
  select * into v_pv from public.presence_verifications where mandate_id = p_mandate_id and expert_id = v_expert;
  return jsonb_build_object(
    'required', public.app_setting_bool('presence_verification_required') and v_m.mandate_type::text <> 'visio',
    'verified', v_m.presence_verified_at is not null,
    'method', v_m.presence_method,
    'verified_at', v_m.presence_verified_at,
    'has_email', v_email is not null,
    'email_masked', case when v_email is null then null
                    else left(split_part(v_email, '@', 1), 1) || '•••@' || split_part(v_email, '@', 2) end,
    'code_sent', coalesce(v_pv.send_count, 0) > 0 and v_pv.method = 'email_code',
    'sends_left', 3 - coalesce(v_pv.send_count, 0),
    'attempts_left', case when v_pv.id is null then 5 else greatest(0, 5 - v_pv.attempts) end,
    'expires_at', v_pv.expires_at,
    'locked', v_pv.locked_at is not null,
    'discharge', public.presence_discharge_text());
end $function$;
revoke execute on function public.expert_presence_status(uuid) from public, anon;
grant execute on function public.expert_presence_status(uuid) to authenticated;

-- 8. Démarrage du rapport : vérification exigée quand le réglage est actif
create or replace function public.expert_start_mandate(p_mandate_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype;
begin
    if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
    select * into v_m from public.mandates where id = p_mandate_id for update;
    if not found then raise exception 'Mandat introuvable'; end if;
    if v_m.assigned_expert_id is distinct from v_expert then
        raise exception 'Ce mandat ne vous est pas attribué';
    end if;
    if v_m.status <> 'assigned' then
        raise exception 'Le rapport ne peut être démarré que pour un mandat attribué (statut actuel : %)', v_m.status;
    end if;
    if public.app_setting_bool('presence_verification_required')
       and v_m.mandate_type::text <> 'visio' and v_m.presence_verified_at is null then
        raise exception 'Vérification de présence requise : saisissez le code reçu par le bénéficiaire (ou cochez la décharge s''il n''a pas d''e-mail)';
    end if;
    perform public.transition_mandate_status(p_mandate_id, 'in_progress');
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id)
    values (v_expert, 'intervention_started', p_mandate_id);
end;
$function$;
