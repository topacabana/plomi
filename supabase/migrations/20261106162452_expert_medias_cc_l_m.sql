-- CC L / M : médias de l'expert (photo / vidéo) avec commentaire, cible de précision et titre d'annexe
create table if not exists public.report_media (
  id uuid primary key default gen_random_uuid(),
  mandate_id uuid not null references public.mandates(id) on delete cascade,
  expert_id uuid not null references public.experts(id) on delete cascade,
  step smallint check (step between 1 and 4),
  room text,
  file_url text not null,
  media_type text not null check (media_type in ('photo','video')),
  comment text,
  annex_title text,
  target_x numeric check (target_x between 0 and 100),
  target_y numeric check (target_y between 0 and 100),
  duplicated_from uuid references public.report_media(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((target_x is null) = (target_y is null))
);
create index if not exists report_media_mandate_idx on public.report_media(mandate_id);
alter table public.report_media enable row level security;
drop policy if exists "report_media : expert propriétaire" on public.report_media;
create policy "report_media : expert propriétaire" on public.report_media for select to authenticated
  using (expert_id = public.current_expert_id());
drop policy if exists "report_media : gestionnaire du mandat" on public.report_media;
create policy "report_media : gestionnaire du mandat" on public.report_media for select to authenticated
  using (public.is_manager() and exists (select 1 from public.mandates m where m.id = mandate_id and m.insurance_org_id = public.current_user_organization_id()));

-- contrôle commun : mandat en cours attribué à l'expert
create or replace function public.expert_media_check(p_mandate_id uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  select * into v_m from public.mandates where id = p_mandate_id;
  if not found or v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
  if v_m.status <> 'in_progress' then raise exception 'Les médias ne peuvent être ajoutés que pendant l''intervention'; end if;
  return v_expert;
end $$;

-- Création (après la capture) ou mise à jour (éditeur)
create or replace function public.expert_media_save(p_id uuid, p_mandate_id uuid, p_file_url text, p_media_type text,
  p_comment text default null, p_annex_title text default null, p_target_x numeric default null, p_target_y numeric default null,
  p_step smallint default null, p_room text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_expert uuid := public.expert_media_check(p_mandate_id); v_row public.report_media%rowtype;
begin
  if p_id is null then
    if coalesce(p_file_url,'') !~ ('/documents/rapports/' || p_mandate_id::text || '/') then
      raise exception 'Fichier non rattaché à ce mandat'; end if;
    insert into public.report_media (mandate_id, expert_id, step, room, file_url, media_type, comment, annex_title, target_x, target_y)
    values (p_mandate_id, v_expert, p_step, nullif(trim(p_room),''), p_file_url,
            case when p_media_type in ('photo','video') then p_media_type
                 when p_media_type like 'video/%' then 'video' else 'photo' end,
            nullif(trim(p_comment),''), nullif(trim(p_annex_title),''), p_target_x, p_target_y)
    returning * into v_row;
  else
    update public.report_media set comment = nullif(trim(p_comment),''), annex_title = nullif(trim(p_annex_title),''),
           target_x = p_target_x, target_y = p_target_y,
           step = coalesce(p_step, step), room = coalesce(nullif(trim(p_room),''), room), updated_at = now()
     where id = p_id and expert_id = v_expert and mandate_id = p_mandate_id
    returning * into v_row;
    if v_row.id is null then raise exception 'Média introuvable'; end if;
  end if;
  return to_jsonb(v_row);
end $$;

-- Duplication : copie du média (même fichier) pour une seconde annotation
create or replace function public.expert_media_duplicate(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_src public.report_media%rowtype; v_row public.report_media%rowtype;
begin
  select * into v_src from public.report_media where id = p_id;
  if not found then raise exception 'Média introuvable'; end if;
  perform public.expert_media_check(v_src.mandate_id);
  if v_src.expert_id <> public.current_expert_id() then raise exception 'Média introuvable'; end if;
  insert into public.report_media (mandate_id, expert_id, step, room, file_url, media_type, comment, duplicated_from)
  values (v_src.mandate_id, v_src.expert_id, v_src.step, v_src.room, v_src.file_url, v_src.media_type, v_src.comment, v_src.id)
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

create or replace function public.expert_media_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_src public.report_media%rowtype;
begin
  select * into v_src from public.report_media where id = p_id;
  if not found then raise exception 'Média introuvable'; end if;
  perform public.expert_media_check(v_src.mandate_id);
  delete from public.report_media where id = p_id and expert_id = public.current_expert_id();
end $$;

-- Liste des médias du mandat (le plus récent d'abord)
create or replace function public.expert_media_list(p_mandate_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb)
    from public.report_media r where r.mandate_id = p_mandate_id and r.expert_id = public.current_expert_id();
$$;

-- Temps passé sur l'outil de capture / retours à la page précédente
create or replace function public.log_expert_media_event(p_mandate_id uuid, p_action text, p_seconds int default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_expert_id() is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if p_action not in ('capture_time','capture_back','editor_back') then raise exception 'Action inconnue'; end if;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'mandate', p_mandate_id, p_action, jsonb_build_object('seconds', p_seconds));
end $$;

revoke all on function public.expert_media_check(uuid) from public, anon, authenticated;
revoke all on function public.expert_media_save(uuid, uuid, text, text, text, text, numeric, numeric, smallint, text),
  public.expert_media_duplicate(uuid), public.expert_media_delete(uuid), public.expert_media_list(uuid),
  public.log_expert_media_event(uuid, text, int) from public, anon;
grant execute on function public.expert_media_save(uuid, uuid, text, text, text, text, numeric, numeric, smallint, text),
  public.expert_media_duplicate(uuid), public.expert_media_delete(uuid), public.expert_media_list(uuid),
  public.log_expert_media_event(uuid, text, int) to authenticated;
