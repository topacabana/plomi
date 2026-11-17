-- Zone de danger : l'archivage avec purge supprime les mandats clôturés et leur historique
-- (correctif de l'anomalie signalée par supabase db lint : suppression dans une vue).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(4);
select tests.seed();
update public.user_profiles set is_supervisor = true where id = 'b0000000-0000-4000-8000-000000000001';

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select public.transition_mandate_status('e0000000-0000-4000-8000-000000000004', 'closed', null, 'Doublon');
select tests.as_postgres();
select ok((select count(*) > 0 from public.activity_logs where entity_type = 'mandate'
            and entity_id = 'e0000000-0000-4000-8000-000000000004'), 'le mandat clôturé a un historique');

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select is((public.supervisor_archive_mandates(null, false))->>'count', '1', 'l''export d''archive contient le mandat clôturé');
select is((public.supervisor_archive_mandates(null, true))->>'deleted', '1', 'la purge supprime le mandat clôturé sans erreur');

select tests.as_postgres();
select is((select count(*)::int from public.activity_logs where entity_type = 'mandate'
            and entity_id = 'e0000000-0000-4000-8000-000000000004'), 0, 'son historique est supprimé avec lui');

select * from finish();
rollback;
