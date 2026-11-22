-- Lecture des liens RDF ↔ RDFS pour la fiche mandat du gestionnaire, et des experts à qui attribuer un RDFS.
create or replace function public.manager_rdfs_links(p_mandate_id uuid)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_user_organization_id();
  v_m public.mandates%rowtype;
  v_parent jsonb; v_child jsonb; v_reason text; v_experts jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select * into v_m from public.mandates where id = p_mandate_id and insurance_org_id = v_org;
  if not found then raise exception 'Mandat introuvable dans votre organisation'; end if;

  select jsonb_build_object('id', p.id, 'reference', p.reference, 'status', p.status)
    into v_parent from public.mandates p where p.id = v_m.parent_mandate_id and p.insurance_org_id = v_org;
  select jsonb_build_object('id', c.id, 'reference', c.reference, 'status', c.status)
    into v_child from public.mandates c
   where c.parent_mandate_id = v_m.id and c.status <> 'cancelled' and c.insurance_org_id = v_org
   order by c.created_at desc limit 1;

  v_reason := case
    when v_m.mandate_type::text <> 'rdf' then 'Seul un mandat RDF peut donner lieu à un RDFS.'
    when v_child is not null then 'Un RDFS existe déjà pour ce dossier.'
    when not exists (select 1 from public.rdf_reports r where r.mandate_id = v_m.id and r.status in ('submitted','validated'))
      then 'Le rapport RDF doit d''abord être reçu.'
    else null end;

  select coalesce(jsonb_agg(jsonb_build_object('value', e.id,
           'label', concat_ws(' ', e.first_name, e.last_name) || coalesce(' — ' || nullif(e.company_name, ''), ''))
           order by e.last_name, e.first_name), '[]'::jsonb)
    into v_experts
    from public.experts e
    join public.org_experts oe on oe.expert_id = e.id and oe.organization_id = v_org
   where coalesce(e.status_experts::text, 'new') <> 'suspendu'
     and not exists (select 1 from public.cgu_versions cv where cv.is_current and e.cgu_version is distinct from cv.version);

  return jsonb_build_object('can_create', v_reason is null, 'reason', v_reason,
                            'parent', v_parent, 'child', v_child, 'experts', v_experts);
end $function$;
revoke execute on function public.manager_rdfs_links(uuid) from public, anon;
grant execute on function public.manager_rdfs_links(uuid) to authenticated;
