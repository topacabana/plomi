-- F14/F32: listes d'experts nommees, gerees par l'agence (mandataire), pour attribution groupee
create table public.expert_lists (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  description text,
  color text,
  is_active boolean not null default true,
  created_by_user_id uuid references public.user_profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.expert_lists is 'F14/F32 - Listes d''experts nommees, gerees par organisation (agence mandataire), pour le drop liste et l''attribution groupee.';

create table public.expert_list_members (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.expert_lists(id) on delete cascade,
  expert_id uuid not null references public.experts(id) on delete cascade,
  added_by_user_id uuid references public.user_profiles(id),
  added_at timestamptz not null default now(),
  unique (list_id, expert_id)
);

comment on table public.expert_list_members is 'Association many-to-many entre expert_lists et experts, meme pattern que expert_profile_assignments.';

create index idx_expert_lists_organization on public.expert_lists (organization_id);
create index idx_expert_list_members_list on public.expert_list_members (list_id);
create index idx_expert_list_members_expert on public.expert_list_members (expert_id);

-- Relie un drop-liste (mandate_assignments.assignment_type = 'redrop_list' ou futur 'list') a la liste utilisee
alter table public.mandate_assignments
  add column list_id uuid references public.expert_lists(id);

comment on column public.mandate_assignments.list_id is 'F14 - Liste d''experts utilisee pour cette attribution, quand assignment_type le justifie (drop liste / redrop_list).';

-- RLS: seuls les membres de l'organisation proprietaire de la liste peuvent la gerer
alter table public.expert_lists enable row level security;
alter table public.expert_list_members enable row level security;

create policy "org members manage their expert lists"
  on public.expert_lists
  for all
  using (organization_id = current_user_organization_id())
  with check (organization_id = current_user_organization_id());

create policy "org members manage their expert list members"
  on public.expert_list_members
  for all
  using (exists (
    select 1 from public.expert_lists l
    where l.id = expert_list_members.list_id
      and l.organization_id = current_user_organization_id()
  ))
  with check (exists (
    select 1 from public.expert_lists l
    where l.id = expert_list_members.list_id
      and l.organization_id = current_user_organization_id()
  ));
