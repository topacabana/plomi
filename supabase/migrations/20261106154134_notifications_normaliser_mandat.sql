-- Les notifications portent l'identifiant du mandat tantôt dans mandate_id, tantôt dans entity_id.
-- Normalisation : les deux sont renseignés dès qu'un mandat est concerné (clic → bon mandat).
create or replace function public.trg_notifications_normaliser()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if new.mandate_id is null and new.entity_type::text = 'mandate' and new.entity_id is not null then
    new.mandate_id := new.entity_id;
  end if;
  if new.mandate_id is null and new.entity_type::text = 'report' and new.entity_id is not null then
    select mandate_id into new.mandate_id from public.rdf_reports where id = new.entity_id;
  end if;
  if new.mandate_id is not null and new.entity_id is null then
    new.entity_id := new.mandate_id;
    new.entity_type := coalesce(new.entity_type, 'mandate');
    new.target_type := coalesce(new.target_type, 'mandate_details');
  end if;
  return new;
end $$;
revoke execute on function public.trg_notifications_normaliser() from public, anon, authenticated;
drop trigger if exists notifications_normaliser on public.notifications;
create trigger notifications_normaliser before insert or update of mandate_id, entity_id, entity_type on public.notifications
  for each row execute function public.trg_notifications_normaliser();

update public.notifications set mandate_id = entity_id where mandate_id is null and entity_type::text = 'mandate' and entity_id is not null;
update public.notifications n set mandate_id = r.mandate_id from public.rdf_reports r
 where n.mandate_id is null and n.entity_type::text = 'report' and r.id = n.entity_id;
update public.notifications set entity_id = mandate_id where mandate_id is not null and entity_id is null;
