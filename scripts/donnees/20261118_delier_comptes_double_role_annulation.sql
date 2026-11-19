-- PLOMI — Retour arrière de 20261118_delier_comptes_double_role.sql
-- Rattache de nouveau les 5 fiches expert aux comptes gestionnaires, puis supprime les comptes experts dédiés.

begin;

update public.experts e set user_id = v.ancien_user
from (values
  ('35152001-fbc1-492e-b592-b42e9d19d81d'::uuid, '51bd0c83-94f1-4274-b3e3-16fd853d5616'::uuid),
  ('8a340f22-ca3d-4406-963e-9619c3e63251', '00000002-0000-4000-8000-000000000002'),
  ('88e2260b-863c-4ca8-a4f4-8ecfbeb2f532', '00000002-0000-4000-8000-000000000001'),
  ('9f31d1af-ebc9-4827-8a0b-b6b2fdd50c0d', '00000002-0000-4000-8000-000000000004'),
  ('96f4309e-bd97-40c6-a6bb-6891d5abd816', '00000002-0000-4000-8000-000000000003')
) v(expert_id, ancien_user)
where e.id = v.expert_id;

-- user_profiles suit par ON DELETE CASCADE
delete from auth.users where id in (
  'f1000000-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000002',
  'f1000000-0000-4000-8000-000000000003', 'f1000000-0000-4000-8000-000000000004',
  'f1000000-0000-4000-8000-000000000005');

commit;
