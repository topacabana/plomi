alter table public.experts add column if not exists agreements text[] not null default '{}';
do $$ begin
  alter table public.experts add constraint chk_experts_agreements check (agreements <@ array['visio','rdf','rdfs']::text[]);
exception when duplicate_object then null;
end $$;
comment on column public.experts.agreements is 'Agréments donnés par le gestionnaire : visio, rdf, rdfs. Full agrément = les trois.';
