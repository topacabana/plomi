-- Documentation dans le schéma des noms hérités du début du projet (organisation de gestion ≠ assureur donneur d'ordre).
comment on column public.mandates.insurance_org_id is
  'Organisation de GESTION propriétaire du mandat (aujourd''hui VELAY BAT), pas l''assureur. Nom hérité du début du projet. L''assureur donneur d''ordre est insurer_id (table insurers).';
comment on column public.mandates.insurer_id is
  'Assureur donneur d''ordre (table insurers) : envoie le mandat par CSV, reçoit le rapport. NULL pour une demande de particulier ou d''entreprise tierce.';
comment on column public.mandates.insurer_file_number is
  'N° de dossier chez l''assureur donneur d''ordre (colonne du CSV), unique par assureur hors mandats annulés et RDFS de suite.';
comment on type public.app_role is
  'Rôles applicatifs. gestionnaire_assurance = gestionnaire de l''organisation de gestion (salarié de VELAY BAT), nom hérité ; expert = expert de terrain.';
comment on type public.organization_type is
  'insurance = organisation de GESTION (structure qui exploite PLOMI, ex. VELAY BAT), nom hérité ; expert_company = société d''appartenance des experts.';
comment on table public.insurers is
  'Assureurs donneurs d''ordre d''une organisation de gestion : ne se connectent pas à PLOMI ; transmettent leurs mandats par CSV (API à terme).';
comment on table public.organizations is
  'Organisations : structures de gestion (type insurance, nom hérité) qui exploitent PLOMI, et sociétés d''appartenance des experts (type expert_company).';
