-- Règles métier (23/11/2026) :
-- 1. Un expert ne voit jamais un mandat sans position (il ne peut rien en faire et ne contacte pas le client) :
--    la vue available_mandates_for_expert exclut les mandats non localisés (carte ET liste).
-- 2. Diffusion (dropped / redrop) : mandat complet ET localisé. Refus si le géocodage a échoué, ou s'il n'a rien
--    donné plus de 2 minutes après la création (le géocodage d'un mandat neuf est asynchrone : quelques secondes).
-- 3. Liste de drop et au-delà : bénéficiaire avec nom, prénom et (téléphone ou e-mail).
do $do$
declare v_def text := pg_get_viewdef('public.available_mandates_for_expert'::regclass);
begin
  if position('latitude IS NOT NULL AND' in v_def) > 0 then return; end if;
  v_def := rtrim(btrim(v_def), ';');
  execute 'create or replace view public.available_mandates_for_expert as ' || v_def
       || ' AND m.latitude IS NOT NULL AND m.longitude IS NOT NULL AND NOT (m.latitude = 0::numeric AND m.longitude = 0::numeric)';
end $do$;

create or replace function public.trg_mandate_completion_guard()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
declare v_b public.beneficiaries%rowtype;
begin
  if new.status is distinct from old.status
     and old.status::text in ('draft', 'new', 'drop_pending')
     and new.status::text in ('dropped', 'redrop', 'assigned')
     and new.completion_status <> 'complete' then
    raise exception 'Mandat % incomplet : 3 créneaux sont nécessaires avant de le diffuser ou de l''attribuer. Complétez-le ou demandez les informations au client depuis la fiche mandat.', coalesce(new.reference, '');
  end if;
  if new.status is distinct from old.status
     and new.status::text in ('dropped', 'redrop')
     and (new.latitude is null or new.longitude is null)
     and (new.geocode_error is not null or new.geocoded_at is not null or new.created_at < now() - interval '2 minutes') then
    raise exception 'Mandat % non localisé : l''adresse n''a pas pu être placée sur la carte. Corrigez l''adresse avant de le diffuser.', coalesce(new.reference, '');
  end if;
  if new.status is distinct from old.status
     and new.status::text in ('drop_pending', 'dropped', 'redrop', 'assigned') then
    select * into v_b from public.beneficiaries where id = new.beneficiary_id;
    if coalesce(btrim(v_b.last_name), '') = '' or coalesce(btrim(v_b.first_name), '') = ''
       or (coalesce(btrim(v_b.mobile_phone), '') = '' and coalesce(btrim(v_b.landline_phone), '') = '' and coalesce(btrim(v_b.email), '') = '') then
      raise exception 'Mandat % : le bénéficiaire doit avoir un nom, un prénom et un téléphone ou un e-mail.', coalesce(new.reference, '');
    end if;
  end if;
  return new;
end $function$;

-- Même contrôle bénéficiaire pour un mandat créé directement en liste de drop ou diffusé
create or replace function public.trg_mandate_beneficiary_guard_insert()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
declare v_b public.beneficiaries%rowtype;
begin
  if new.status::text in ('drop_pending', 'dropped', 'redrop', 'assigned') then
    select * into v_b from public.beneficiaries where id = new.beneficiary_id;
    if coalesce(btrim(v_b.last_name), '') = '' or coalesce(btrim(v_b.first_name), '') = ''
       or (coalesce(btrim(v_b.mobile_phone), '') = '' and coalesce(btrim(v_b.landline_phone), '') = '' and coalesce(btrim(v_b.email), '') = '') then
      raise exception 'Le bénéficiaire doit avoir un nom, un prénom et un téléphone ou un e-mail.';
    end if;
  end if;
  return new;
end $function$;
drop trigger if exists mandate_beneficiary_guard_insert on public.mandates;
create trigger mandate_beneficiary_guard_insert before insert on public.mandates
  for each row execute function public.trg_mandate_beneficiary_guard_insert();
