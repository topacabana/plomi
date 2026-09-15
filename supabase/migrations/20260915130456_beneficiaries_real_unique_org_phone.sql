DROP INDEX IF EXISTS public.beneficiaries_org_phone_unique;
ALTER TABLE public.beneficiaries
  ADD CONSTRAINT beneficiaries_org_phone_key UNIQUE (organization_id, mobile_phone);
