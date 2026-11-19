-- 19/11/2026 : deux fiches expert de démonstration portaient le nom du gestionnaire
-- (« Thomas Cadelis » et « Cadelis Thomas »). On leur redonne le nom de leur compte.
begin;
update public.experts
   set first_name = 'Sophie', last_name = 'Delorme', company_name = 'ExpertPlomb IDF', updated_at = now()
 where id = '00000004-0000-4000-8000-000000000001';
update public.experts
   set first_name = 'Michel', last_name = 'Bernard', updated_at = now()
 where id = '35152001-fbc1-492e-b592-b42e9d19d81d';
update public.user_profiles set first_name = 'Sophie', last_name = 'Delorme', updated_at = now()
 where id = 'c5f368d4-4679-4d62-b04d-5d297330a2cc';
update public.user_profiles set first_name = 'Michel', last_name = 'Bernard', updated_at = now()
 where id = 'f1000000-0000-4000-8000-000000000001';
commit;
