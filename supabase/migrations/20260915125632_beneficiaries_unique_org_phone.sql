CREATE UNIQUE INDEX IF NOT EXISTS beneficiaries_org_phone_unique
ON public.beneficiaries (organization_id, mobile_phone)
WHERE mobile_phone IS NOT NULL AND length(mobile_phone) > 3;
