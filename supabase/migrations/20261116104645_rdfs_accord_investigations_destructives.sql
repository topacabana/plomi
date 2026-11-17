-- CGU art. 7.7 : accord préalable du bénéficiaire avant investigations destructives (RDFS).
-- Accord recueilli sur place, sur le téléphone de l'expert : le bénéficiaire saisit son nom et coche l'accord.

create table if not exists public.destructive_consents (
  id               uuid primary key default gen_random_uuid(),
  mandate_id       uuid not null references public.mandates(id) on delete cascade,
  expert_id        uuid not null references public.experts(id),
  signatory_name   text not null check (length(btrim(signatory_name)) between 2 and 120),
  signatory_role   text not null check (signatory_role in ('beneficiaire', 'occupant', 'representant')),
  works            text not null check (length(btrim(works)) between 3 and 500),
  consent_text     text not null,
  consent_version  text not null,
  consented_at     timestamptz not null default now(),
  created_by       uuid not null default auth.uid()
);
create index if not exists destructive_consents_mandate_idx on public.destructive_consents (mandate_id);

alter table public.destructive_consents enable row level security;

drop policy if exists "accords destructifs : expert du mandat" on public.destructive_consents;
create policy "accords destructifs : expert du mandat" on public.destructive_consents
  for select to authenticated using (expert_id = public.current_expert_id());

drop policy if exists "accords destructifs : gestionnaire du mandat" on public.destructive_consents;
create policy "accords destructifs : gestionnaire du mandat" on public.destructive_consents
  for select to authenticated using (
    public.is_manager() and exists (
      select 1 from public.mandates m
      where m.id = destructive_consents.mandate_id
        and m.insurance_org_id = public.current_user_organization_id()));

revoke insert, update, delete on public.destructive_consents from anon, authenticated;

-- Texte présenté au bénéficiaire (versionné)
create or replace function public.destructive_consent_text()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'version', '2026-11-16',
    'text',
    'J''autorise l''expert mandaté par mon assureur, par l''intermédiaire de VELAY BAT, à réaliser les investigations destructives décrites ci-dessus (perçage, ouverture de cloison, dépose de revêtement), nécessaires à la localisation de la fuite. J''ai été informé(e) que des photos seront prises avant et après, que les ouvertures seront consignées dans le rapport et que leur remise en état relève de la prise en charge du sinistre par mon assureur.'
  );
$$;

grant execute on function public.destructive_consent_text() to authenticated;

-- Enregistrement par l'expert attribué, pendant la mission
create or replace function public.expert_record_destructive_consent(
  p_mandate_id uuid,
  p_signatory_name text,
  p_signatory_role text,
  p_works text,
  p_version text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_expert uuid := public.current_expert_id();
  v_m public.mandates%rowtype;
  v_txt jsonb := public.destructive_consent_text();
  v_id uuid;
begin
  if v_expert is null then
    return jsonb_build_object('ok', false, 'error', 'Aucun profil expert trouvé pour cet utilisateur.');
  end if;
  select * into v_m from public.mandates where id = p_mandate_id;
  if not found or v_m.assigned_expert_id is distinct from v_expert then
    return jsonb_build_object('ok', false, 'error', 'Ce mandat ne vous est pas attribué.');
  end if;
  if v_m.status not in ('assigned', 'in_progress') then
    return jsonb_build_object('ok', false, 'error', 'L''accord ne peut être recueilli que pendant la mission.');
  end if;
  if p_version is distinct from v_txt->>'version' then
    return jsonb_build_object('ok', false, 'error', 'Le texte d''accord a changé : rechargez la page.');
  end if;
  if coalesce(length(btrim(p_signatory_name)), 0) < 2 then
    return jsonb_build_object('ok', false, 'error', 'Le bénéficiaire doit saisir son nom.');
  end if;
  if p_signatory_role not in ('beneficiaire', 'occupant', 'representant') then
    return jsonb_build_object('ok', false, 'error', 'Précisez la qualité du signataire.');
  end if;
  if coalesce(length(btrim(p_works)), 0) < 3 then
    return jsonb_build_object('ok', false, 'error', 'Décrivez les investigations prévues.');
  end if;

  insert into public.destructive_consents
    (mandate_id, expert_id, signatory_name, signatory_role, works, consent_text, consent_version)
  values
    (p_mandate_id, v_expert, btrim(p_signatory_name), p_signatory_role, btrim(p_works),
     v_txt->>'text', v_txt->>'version')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'consented_at', now());
end;
$$;

-- Accords du mandat (expert attribué ou gestionnaire de l'organisation, via RLS)
create or replace function public.mandate_destructive_consents(p_mandate_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id,
           'signataire', c.signatory_name,
           'qualite', c.signatory_role,
           'travaux', c.works,
           'version', c.consent_version,
           'le', c.consented_at) order by c.consented_at), '[]'::jsonb)
  from public.destructive_consents c
  where c.mandate_id = p_mandate_id;
$$;

revoke all on function public.expert_record_destructive_consent(uuid, text, text, text, text) from public, anon;
revoke all on function public.mandate_destructive_consents(uuid) from public, anon;
grant execute on function public.expert_record_destructive_consent(uuid, text, text, text, text) to authenticated;
grant execute on function public.mandate_destructive_consents(uuid) to authenticated;
