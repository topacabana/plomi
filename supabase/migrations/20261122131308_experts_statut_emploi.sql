alter table public.experts
  add column if not exists employment_status text not null default 'independant'
  check (employment_status in ('salarie_velaybat', 'independant'));

comment on column public.experts.employment_status is
  'Lien de l''expert avec VELAY BAT : salarie_velaybat (phase 1, experts internes) ou independant (prestataire, phase 2 : contrat de prestation et CGU à faire rédiger par un juriste). Distinct de contract_type, qui est la forme juridique de l''entreprise d''un indépendant (AE, EI, SARL…).';
comment on column public.experts.contract_type is
  'Forme juridique de l''entreprise de l''expert indépendant (AE, EI, EURL, SARL, SAS, SASU, SA, Autre). Vide pour un salarié de VELAY BAT.';
