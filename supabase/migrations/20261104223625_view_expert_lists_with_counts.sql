create or replace view public.expert_lists_with_counts
with (security_invoker = true) as
select l.id, l.organization_id, l.name, l.description, l.color, l.is_active, l.created_at,
       (select count(*) from public.expert_list_members m where m.list_id = l.id)::int as member_count
from public.expert_lists l
where coalesce(l.is_active, true);
grant select on public.expert_lists_with_counts to authenticated;
