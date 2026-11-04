create or replace function public.auto_suspend_overdue_mandates()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    r record;
    n integer := 0;
begin
    for r in
        select m.id
        from public.mandates m
        left join lateral (
            select a.assignment_type
            from public.mandate_assignments a
            where a.mandate_id = m.id and a.status in ('pending','accepted')
            order by a.assigned_at desc limit 1
        ) a on true
        where (m.status = 'assigned' and m.started_at is null and m.assigned_at is not null
               and now() > case
                    when a.assignment_type = 'manual' then m.assigned_at + interval '48 hours'
                    when m.selected_slot_at is not null then m.selected_slot_at + interval '30 minutes'
                    else (date_trunc('day', m.assigned_at at time zone 'Europe/Paris') + interval '1 day') at time zone 'Europe/Paris'
               end)
           or (m.status = 'in_progress' and m.started_at is not null
               and now() > m.started_at + interval '2 hours')
    loop
        perform public.transition_mandate_status(r.id, 'suspended');
        update public.mandates
           set motif_abandon = 'Suspension automatique : délai dépassé', date_abandon = now()
         where id = r.id;
        -- Attribution manuelle jamais démarrée : expirée (pénalité KPI : mandate_expired + redrop_caused)
        update public.mandate_assignments
           set status = 'expired', comment = coalesce(comment, 'Délai de 48 h dépassé sans démarrage')
         where mandate_id = r.id and status = 'pending';
        n := n + 1;
    end loop;
    return n;
end;
$function$;
