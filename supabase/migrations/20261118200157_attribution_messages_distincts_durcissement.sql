-- Jeu d'essai de l'attribution manuelle (tests/jeu-essai-attribution-manuelle.md), écarts 1 et 2 :
--   1. un expert suspendu et un expert hors base ne donnent plus le même message ;
--   2. chaque erreur du compte rendu porte le nom de l'expert (un même mandat peut figurer deux fois dans le lot).
-- Plus deux alertes du conseiller Supabase et un durcissement :
--   - is_supervisor() n'est plus exécutable par les visiteurs non connectés (anon) ;
--   - destructive_consent_text() a un search_path fixe ;
--   - create_expert_record() n'est exécutable que par le serveur (service_role) : elle le vérifiait déjà
--     en première ligne (« Réservé au serveur »), le droit d'exécution est maintenant retiré aussi.

create or replace function public.manual_assign_mandates(p_assignments jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_org uuid := public.current_user_organization_id(); r jsonb; v_ok int := 0; v_err jsonb := '[]'::jsonb;
        v_m uuid; v_e uuid; v_nom text; v_statut text;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if p_assignments is null or jsonb_typeof(p_assignments) <> 'array' or jsonb_array_length(p_assignments) = 0 then
    raise exception 'Aucune attribution à enregistrer';
  end if;
  for r in select * from jsonb_array_elements(p_assignments) loop
    v_m := (r->>'mandate_id')::uuid; v_e := (r->>'expert_id')::uuid;
    v_nom := coalesce(public.expert_display_name(v_e), 'expert inconnu');
    begin
      if not exists (select 1 from public.mandates where id = v_m and insurance_org_id = v_org) then
        raise exception 'Mandat introuvable dans votre organisation';
      end if;
      if not exists (select 1 from public.org_experts oe where oe.expert_id = v_e and oe.organization_id = v_org) then
        raise exception 'Recrutez d''abord l''expert dans votre base';
      end if;
      select coalesce(e.status_experts::text, 'new') into v_statut from public.experts e where e.id = v_e;
      if v_statut = 'suspendu' then
        raise exception 'Expert suspendu';
      end if;
      perform public.transition_mandate_status(v_m, 'assigned', v_e, null, 'manual');
      v_ok := v_ok + 1;
    exception when others then
      v_err := v_err || jsonb_build_object(
                 'mandate_id', v_m,
                 'reference', (select reference from public.mandates where id = v_m and insurance_org_id = v_org),
                 'expert_id', v_e,
                 'expert_name', v_nom,
                 'error', sqlerrm || ' (' || v_nom || ')');
    end;
  end loop;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', gen_random_uuid(), 'manual_assignment',
          jsonb_build_object('requested', jsonb_array_length(p_assignments), 'assigned', v_ok, 'errors', v_err));
  return jsonb_build_object('assigned', v_ok, 'errors', v_err);
end $function$;

revoke execute on function public.manual_assign_mandates(jsonb) from public, anon;
grant execute on function public.manual_assign_mandates(jsonb) to authenticated;

-- Alertes du conseiller Supabase
revoke execute on function public.is_supervisor() from public, anon;
grant execute on function public.is_supervisor() to authenticated;

alter function public.destructive_consent_text() set search_path = '';

-- Défense en profondeur : création de fiche expert réservée à l'Edge Function (clé service)
revoke execute on function public.create_expert_record(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.create_expert_record(uuid, uuid, jsonb) to service_role;
