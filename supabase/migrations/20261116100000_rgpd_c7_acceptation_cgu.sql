-- C7 : acceptation tracée des CGU experts (version + date), contrôle serveur sur la prise de mandat.

create table if not exists public.cgu_versions (
  version      text primary key,
  title        text not null,
  content      text not null,
  published_at timestamptz not null default now(),
  is_current   boolean not null default false
);
create unique index if not exists cgu_versions_one_current on public.cgu_versions (is_current) where is_current;

alter table public.cgu_versions enable row level security;
drop policy if exists cgu_versions_read on public.cgu_versions;
create policy cgu_versions_read on public.cgu_versions for select to authenticated using (true);
revoke insert, update, delete on public.cgu_versions from anon, authenticated;

alter table public.experts
  add column if not exists cgu_version text references public.cgu_versions(version),
  add column if not exists cgu_accepted_at timestamptz;

insert into public.cgu_versions (version, title, is_current, content) values (
'2026-11-16',
'Conditions générales d''utilisation — PLOMI Expert',
true,
$cgu$[Préambule, objet, inscription, missions, rémunération et autres articles des CGU à compléter]

Article [X] — Confidentialité et protection des données

[X].1 — Informations confidentielles. Sont confidentielles toutes les informations auxquelles l'Expert accède par PLOMI ou à l'occasion d'une mission : identité et coordonnées des assurés et des occupants, adresse et description des lieux, photographies, contenu des mandats et des rapports, informations sur les assureurs et leurs procédures.

[X].2 — Usage limité à la mission. L'Expert n'utilise ces informations que pour exécuter la mission qui lui a été confiée, conformément aux instructions de l'assureur transmises par PLOMI. Il agit pour le compte de l'assureur, responsable de traitement, et de VELAY BAT, son sous-traitant ; il ne détermine pas lui-même la finalité des traitements.

[X].3 — Interdictions. Il est interdit à l'Expert :
• de communiquer ces informations à un tiers, y compris à un autre assureur ou à un artisan, sauf instruction écrite de l'assureur ;
• de les copier, exporter ou conserver hors de PLOMI (téléphone personnel, messagerie, cloud privé), à l'exception des copies temporaires strictement nécessaires à la mission, supprimées dès son dépôt ;
• de photographier des personnes, des documents d'identité ou bancaires, ou des pièces et objets sans lien avec le sinistre ;
• de contacter l'assuré pour un motif autre que la mission, notamment commercial ;
• de saisir dans PLOMI des données relatives à la santé, aux opinions, à la religion, à la vie sexuelle, à l'origine ou aux infractions, ou des appréciations sur les personnes.

[X].4 — Personnel et sous-traitance. L'Expert veille à ce que toute personne qui l'assiste soit tenue à la même confidentialité. Il ne peut confier une mission à un tiers sans l'accord préalable de l'assureur, donné par PLOMI.

[X].5 — Sécurité du compte. Les identifiants sont personnels et ne doivent pas être partagés. L'Expert protège son appareil par un code de verrouillage, se déconnecte des appareils partagés et maintient à jour son système et son navigateur.

[X].6 — Signalement. L'Expert signale à VELAY BAT, au plus tard 24 heures après en avoir eu connaissance, toute perte ou vol d'appareil, tout accès suspect à son compte et toute divulgation, même accidentelle, d'informations confidentielles, à l'adresse [adresse e-mail RGPD]. Il collabore aux mesures décidées pour en limiter les effets.

[X].7 — Fin de mission et fin de partenariat. À la clôture de chaque mission, et au plus tard à la fin du partenariat, l'Expert supprime toute copie qu'il détiendrait hors de PLOMI. L'obligation de confidentialité survit 5 ans après la fin du partenariat, sans limite de durée pour les données personnelles des assurés.

[X].8 — Manquement. Tout manquement au présent article peut entraîner la suspension immédiate de l'accès à PLOMI et la résiliation du partenariat, sans préjudice de dommages et intérêts et de la responsabilité propre de l'Expert au titre du RGPD.

[X].9 — Données de l'Expert. Le traitement des données personnelles de l'Expert par VELAY BAT est décrit dans la politique de confidentialité accessible depuis la page Profil de l'application.$cgu$
) on conflict (version) do nothing;

-- Statut pour l'expert connecté
create or replace function public.expert_cgu_status()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_cur public.cgu_versions%rowtype;
  v_exp public.experts%rowtype;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Connexion requise.');
  end if;
  select * into v_cur from public.cgu_versions where is_current;
  select * into v_exp from public.experts where user_id = auth.uid() limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'is_expert', false, 'needs_acceptance', false);
  end if;
  return jsonb_build_object(
    'ok', true,
    'is_expert', true,
    'current_version', v_cur.version,
    'title', v_cur.title,
    'content', v_cur.content,
    'accepted_version', v_exp.cgu_version,
    'accepted_at', v_exp.cgu_accepted_at,
    'needs_acceptance', v_cur.version is not null and v_exp.cgu_version is distinct from v_cur.version
  );
end;
$$;

-- Acceptation par l'expert connecté
create or replace function public.expert_accept_cgu(p_version text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_cur text;
  v_exp public.experts%rowtype;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Connexion requise.');
  end if;
  select version into v_cur from public.cgu_versions where is_current;
  if p_version is distinct from v_cur then
    return jsonb_build_object('ok', false, 'error', 'Les conditions ont changé : rechargez la page.');
  end if;
  select * into v_exp from public.experts where user_id = auth.uid() limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Aucune fiche expert rattachée à ce compte.');
  end if;

  update public.experts set cgu_version = v_cur, cgu_accepted_at = now() where id = v_exp.id;

  insert into public.activity_logs (user_id, organization_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), v_exp.organization_id, 'user', auth.uid(), 'cgu_accepted',
          jsonb_build_object('version', v_cur));

  return jsonb_build_object('ok', true, 'version', v_cur, 'accepted_at', now());
end;
$$;

revoke all on function public.expert_cgu_status() from public, anon;
revoke all on function public.expert_accept_cgu(text) from public, anon;
grant execute on function public.expert_cgu_status() to authenticated;
grant execute on function public.expert_accept_cgu(text) to authenticated;

-- Garde serveur : pas de prise de mandat sans CGU en vigueur acceptées
do $do$
declare
  v_def text := pg_get_functiondef('public.expert_claim_mandate(uuid, timestamptz)'::regprocedure);
  v_anchor text := E'raise exception ''Aucun profil expert trouvé pour cet utilisateur'';\n    end if;\n';
begin
  if position('cgu_version' in v_def) = 0 then
    if position(v_anchor in v_def) = 0 then
      raise exception 'Ancre introuvable dans expert_claim_mandate';
    end if;
    execute replace(v_def, v_anchor, v_anchor ||
      E'\n    if exists (select 1 from public.cgu_versions c where c.is_current)\n'
      || E'       and not exists (select 1 from public.experts e join public.cgu_versions c on c.version = e.cgu_version and c.is_current where e.id = v_expert_id) then\n'
      || E'        raise exception ''Veuillez accepter les conditions générales d''''utilisation avant de prendre un mandat'';\n'
      || E'    end if;\n');
  end if;
end;
$do$;

-- Export « mes données » : identité réelle du responsable
do $do$
declare
  v_def text := pg_get_functiondef('public.expert_export_my_data()'::regprocedure);
begin
  execute replace(v_def,
    'PLOMI — [raison sociale, adresse et contact du DPO à compléter]',
    'VELAY BAT, SARL, SIRET 795 313 857 00026, 35 rue des Broderies, 78310 Coignières — référent RGPD : Thomas Cadelis');
end;
$do$;
