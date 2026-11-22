-- RDFS en suite d'un RDF : mandat RDFS lié (même dossier assureur), créé d'un clic par le gestionnaire,
-- puis droppé (premier drop, pas de redrop) ou attribué directement à un expert de sa base.
-- Le RDF reste intact (rapport, pièces, photos, PDF) ; les deux fiches se renvoient l'une à l'autre.
alter table public.mandates add column if not exists parent_mandate_id uuid
  references public.mandates(id) on delete set null;
create index if not exists mandates_parent_idx on public.mandates (parent_mandate_id);
comment on column public.mandates.parent_mandate_id is 'RDFS : mandat RDF dont il est la suite (même sinistre, même n° de dossier assureur).';

-- Un RDF n'a qu'un RDFS de suite (hors annulés)
create unique index if not exists mandates_one_rdfs_followup_uidx on public.mandates (parent_mandate_id)
  where parent_mandate_id is not null and status <> 'cancelled';

-- Le n° de dossier assureur reste unique par assureur, sauf pour le RDFS de suite qui partage celui de son RDF
drop index if exists public.mandates_insurer_file_number_uidx;
create unique index mandates_insurer_file_number_uidx on public.mandates (insurer_id, lower(btrim(insurer_file_number)))
  where insurer_id is not null and insurer_file_number is not null and status <> 'cancelled' and parent_mandate_id is null;

create or replace function public.manager_create_rdfs_followup(
  p_mandate_id uuid, p_mode text, p_expert_id uuid default null, p_list_ids uuid[] default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_user_organization_id();
  v_src public.mandates%rowtype;
  v_row jsonb;
  v_new uuid;
  v_ref text;
  v_res jsonb;
  v_new_ref text;
begin
  if not public.is_manager() then return jsonb_build_object('ok', false, 'error', 'Réservé aux gestionnaires.'); end if;
  if p_mode not in ('drop', 'assign') then return jsonb_build_object('ok', false, 'error', 'Mode inconnu (drop ou assign).'); end if;
  select * into v_src from public.mandates where id = p_mandate_id and insurance_org_id = v_org;
  if not found then return jsonb_build_object('ok', false, 'error', 'Mandat introuvable dans votre organisation.'); end if;
  if v_src.mandate_type::text <> 'rdf' then return jsonb_build_object('ok', false, 'error', 'Seul un mandat RDF peut donner lieu à un RDFS.'); end if;
  if not exists (select 1 from public.rdf_reports r where r.mandate_id = p_mandate_id and r.status in ('submitted', 'validated')) then
    return jsonb_build_object('ok', false, 'error', 'Le rapport RDF doit d''abord être reçu.');
  end if;
  select reference into v_ref from public.mandates where parent_mandate_id = p_mandate_id and status <> 'cancelled' limit 1;
  if v_ref is not null then return jsonb_build_object('ok', false, 'error', 'Un RDFS existe déjà pour ce dossier : ' || v_ref); end if;
  if p_mode = 'assign' and p_expert_id is null then return jsonb_build_object('ok', false, 'error', 'Choisissez l''expert à qui attribuer le RDFS.'); end if;
  -- Référence fille : <réf RDF>-S, puis -S2, -S3… si un RDFS précédent a été annulé
  v_new_ref := v_src.reference || '-S';
  while exists (select 1 from public.mandates where reference = v_new_ref) loop
    v_new_ref := v_src.reference || '-S' || (coalesce(nullif(regexp_replace(v_new_ref, '^.*-S', ''), ''), '1')::int + 1);
  end loop;

  -- Copie du dossier (bénéficiaire, adresse, sinistre, n° assureur, demandeur…), sans rien de l'intervention RDF
  v_row := to_jsonb(v_src)
    - array['id','reference','status','workflow_stage','visible_on_map','drop_at','expiry_at','assigned_at','closed_at',
            'closure_type','redrop_count','assigned_expert_id','expert_first_name','expert_last_name','started_at','dropped_by',
            'slot_1_at','slot_2_at','slot_3_at','selected_slot_at','target_list_ids','motif_abandon','date_abandon',
            'arrived_at','travel_time_min','travel_distance_km','travel_expert_id','travel_computed_at','travel_error',
            'presence_verified_at','presence_method','scheduled_date','scheduled_time_slot','scheduled_date_2','scheduled_date_3',
            'created_at','updated_at','import_id','created_by_user_id','parent_mandate_id','mandate_type'];
  v_row := v_row || jsonb_build_object(
    'id', gen_random_uuid(), 'created_at', now(), 'updated_at', now(), 'visible_on_map', false,
    'reference', v_new_ref, 'mandate_type', 'rdfs', 'status', 'draft', 'parent_mandate_id', v_src.id,
    'created_by_user_id', auth.uid(), 'redrop_count', 0, 'target_list_ids', '{}'::uuid[],
    'description', concat_ws(E'\n', 'RDFS faisant suite au RDF ' || v_src.reference || '.', v_src.description));
  insert into public.mandates select * from jsonb_populate_record(null::public.mandates, v_row) returning id into v_new;

  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'mandate', v_src.id, 'rdfs_followup_created',
          jsonb_build_object('rdfs_mandate_id', v_new, 'rdfs_reference', v_new_ref, 'mode', p_mode));

  if p_mode = 'drop' then
    perform public.drop_mandate(v_new, p_list_ids);           -- premier drop du RDFS : statut « dropped », pas « redrop »
  else
    perform public.transition_mandate_status(v_new, 'drop_pending');
    v_res := public.manual_assign_mandates(jsonb_build_array(jsonb_build_object('mandate_id', v_new, 'expert_id', p_expert_id)));
    if coalesce((v_res->>'assigned')::int, 0) = 0 then
      raise exception '%', coalesce(v_res->'errors'->0->>'error', 'Attribution impossible');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'mandate_id', v_new, 'reference', v_new_ref);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $function$;
revoke execute on function public.manager_create_rdfs_followup(uuid, text, uuid, uuid[]) from public, anon;
grant execute on function public.manager_create_rdfs_followup(uuid, text, uuid, uuid[]) to authenticated;
