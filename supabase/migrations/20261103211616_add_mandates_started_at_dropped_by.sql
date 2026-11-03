alter table public.mandates
  add column if not exists started_at timestamptz,
  add column if not exists dropped_by uuid references public.user_profiles(id) on delete set null;
comment on column public.mandates.started_at is 'Heure de passage en in_progress (debut du formulaire de rapport par l''expert). Base du delai de suspension automatique (2h).';
comment on column public.mandates.dropped_by is 'Operateur (user_profiles.id) ayant droppe le mandat.';
