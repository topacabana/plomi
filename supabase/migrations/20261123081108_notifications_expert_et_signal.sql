-- Notifications à l'expert aux étapes qui changent sa carte ou son compte, et signal léger de rafraîchissement.
-- L'app expert ne recharge plus la carte toutes les 30 s (le recadrage gênait les zooms) : elle interroge
-- expert_sync_state() et ne recharge que si une notification est arrivée ou si l'offre de mandats a changé.

-- 1. Attribution : nouveau mandat attribué / attribution retirée (sauf quand l'expert agit lui-même :
--    prise en charge depuis la carte, abandon, interruption).
create or replace function public.trg_notify_expert_assignment()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_new_user uuid; v_old_user uuid;
begin
  if new.assigned_expert_id is not distinct from old.assigned_expert_id then return new; end if;
  select user_id into v_new_user from public.experts where id = new.assigned_expert_id;
  select user_id into v_old_user from public.experts where id = old.assigned_expert_id;

  if v_new_user is not null and v_new_user is distinct from auth.uid() then
    insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
    values (v_new_user, new.id, 'new_assignment', 'Nouveau mandat attribué',
            'Le mandat ' || coalesce(new.reference, '') || ' vous a été attribué'
              || coalesce(' (' || nullif(trim(concat_ws(' ', new.postal_code, new.city)), '') || ')', '') || '.',
            'in_app', false, now(), 'mandate', new.id, 'mandate');
  end if;

  if v_old_user is not null and v_old_user is distinct from auth.uid()
     -- le message groupé « retirer l'attribution » a déjà prévenu l'expert avec son texte
     and not exists (select 1 from public.notifications n
                      where n.user_id = v_old_user and n.mandate_id = new.id
                        and n.title = 'Attribution retirée' and n.created_at >= now() - interval '10 seconds') then
    insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
    values (v_old_user, new.id, 'status_change', 'Attribution retirée',
            'Le mandat ' || coalesce(new.reference, '') || ' vous a été retiré par le gestionnaire.',
            'in_app', false, now(), 'mandate', new.id, 'dashboard');
  end if;
  return new;
end $function$;

drop trigger if exists notify_expert_assignment on public.mandates;
create trigger notify_expert_assignment after update of assigned_expert_id on public.mandates
  for each row execute function public.trg_notify_expert_assignment();

-- 2. Drop ciblé sur des listes d'experts : les membres sont prévenus qu'un mandat les attend sur la carte.
create or replace function public.trg_notify_experts_targeted_drop()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if new.status::text in ('dropped', 'redrop') and old.status is distinct from new.status
     and cardinality(coalesce(new.target_list_ids, '{}')) > 0 then
    insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
    select distinct e.user_id, new.id, 'new_assignment', 'Nouveau mandat disponible',
           'Le mandat ' || coalesce(new.reference, '') || coalesce(' (' || nullif(trim(concat_ws(' ', new.postal_code, new.city)), '') || ')', '')
             || ' est proposé à votre liste : il est sur votre carte.',
           'in_app'::notification_channel, false, now(), 'mandate', new.id, 'dashboard'::notification_target_type
      from public.expert_list_members lm
      join public.experts e on e.id = lm.expert_id
     where lm.list_id = any(new.target_list_ids)
       and e.user_id is not null and e.status_experts::text <> 'suspendu';
  end if;
  return new;
end $function$;

drop trigger if exists notify_experts_targeted_drop on public.mandates;
create trigger notify_experts_targeted_drop after update of status on public.mandates
  for each row execute function public.trg_notify_experts_targeted_drop();

-- 3. Suspension et levée : l'expert est prévenu (les gestionnaires l'étaient déjà).
create or replace function public.trg_notify_expert_own_suspension()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if new.user_id is null then return new; end if;
  if new.status_experts::text = 'suspendu' and old.status_experts::text is distinct from 'suspendu' then
    insert into public.notifications (user_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
    values (new.user_id, 'system', 'Compte suspendu',
            coalesce(new.suspension_reason, 'Suspension') || '. Vous ne voyez plus la carte des mandats jusqu''à la levée par votre gestionnaire.',
            'in_app', false, now(), 'expert', new.id, 'dashboard');
  elsif old.status_experts::text = 'suspendu' and new.status_experts::text <> 'suspendu' then
    insert into public.notifications (user_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
    values (new.user_id, 'system', 'Suspension levée',
            'Votre gestionnaire a levé la suspension : la carte des mandats est de nouveau disponible.',
            'in_app', false, now(), 'expert', new.id, 'dashboard');
  end if;
  return new;
end $function$;

drop trigger if exists notify_expert_own_suspension on public.experts;
create trigger notify_expert_own_suspension after update of status_experts on public.experts
  for each row execute function public.trg_notify_expert_own_suspension();

-- 4. Signal de rafraîchissement : dernière notification reçue et empreinte de l'offre visible.
create or replace function public.expert_sync_state()
 returns jsonb
 language sql
 stable
 security invoker
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'last_notification', (select max(created_at) from public.notifications where user_id = auth.uid()),
    'unread', (select count(*) from public.notifications where user_id = auth.uid() and not is_read),
    'status', (select status_experts::text from public.experts where user_id = auth.uid() limit 1),
    'map', (select count(*)::text || '-' || coalesce(max(updated_at)::text, '') from public.available_mandates_for_expert)
  );
$function$;
revoke all on function public.expert_sync_state() from public, anon;
grant execute on function public.expert_sync_state() to authenticated;
