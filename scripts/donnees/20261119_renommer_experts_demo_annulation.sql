-- Annulation de 20261119_renommer_experts_demo.sql
begin;
update public.experts set first_name = 'Thomas', last_name = 'Cadelis', company_name = 'Gestionnaire'
 where id = '00000004-0000-4000-8000-000000000001';
update public.experts set first_name = 'Cadelis', last_name = 'Thomas'
 where id = '35152001-fbc1-492e-b592-b42e9d19d81d';
update public.user_profiles set first_name = 'Thomas', last_name = 'Cadelis'
 where id = 'c5f368d4-4679-4d62-b04d-5d297330a2cc';
update public.user_profiles set first_name = 'Cadelis', last_name = 'Thomas'
 where id = 'f1000000-0000-4000-8000-000000000001';
commit;
