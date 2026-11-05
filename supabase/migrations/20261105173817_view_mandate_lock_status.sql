-- Verrous actifs, lisibles par l'interface (nom du détenteur, verrou à moi ou non)
create or replace view public.mandate_lock_status as
select l.mandate_id,
       m.reference,
       l.user_id,
       public.lock_holder_name(l.user_id) as holder_name,
       (l.user_id = auth.uid())           as is_mine,
       l.locked_at,
       l.expires_at
  from public.mandate_locks l
  join public.mandates m on m.id = l.mandate_id
 where l.expires_at > now();
grant select on public.mandate_lock_status to authenticated;
