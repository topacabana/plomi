-- Page Détails gestionnaire (superviseur) : fiche complète d'un gestionnaire de l'équipe.
-- Reprend la carte de supervision_dashboard() (aujourd'hui, charge, qualité 30 j) et ajoute
-- l'activité des 14 derniers jours, les dossiers ouverts et un historique long (100 actions).

create or replace function public.manager_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_card jsonb;
  v_since timestamptz := date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris' - interval '13 days';
begin
  if not public.is_supervisor() then raise exception 'Accès réservé au superviseur' using errcode = '42501'; end if;
  select c into v_card from jsonb_array_elements(public.supervision_dashboard()) c where c->>'id' = p_id::text;
  if v_card is null then raise exception 'Gestionnaire introuvable dans votre équipe'; end if;

  return v_card || jsonb_build_object(
    'created_at', (select created_at from user_profiles where id = p_id),
    'last_login_at', (select last_login_at from user_profiles where id = p_id),
    'activity_14d', (
      select jsonb_agg(jsonb_build_object('day', d::date, 'actions', coalesce(n, 0)) order by d)
      from generate_series(v_since at time zone 'Europe/Paris', now() at time zone 'Europe/Paris', interval '1 day') d
      left join (
        select (a.created_at at time zone 'Europe/Paris')::date as day, count(*) n
        from activity_logs a
        where coalesce(a.user_id, nullif(a.new_values_json->>'by', '')::uuid) = p_id and a.created_at >= v_since
        group by 1
      ) x on x.day = d::date),
    'open_mandates', coalesce((
      select jsonb_agg(jsonb_build_object('id', m.id, 'reference', m.reference, 'city', m.city, 'status', m.status,
                                          'status_label', public.mandate_status_label(m.status::text), 'created_at', m.created_at)
                       order by m.created_at desc)
      from (select * from mandates where created_by_user_id = p_id and status::text not in ('closed', 'cancelled')
            order by created_at desc limit 30) m), '[]'::jsonb),
    'history_long', coalesce((
      select jsonb_agg(h order by h->>'at' desc) from (
        select jsonb_build_object(
          'at', l.created_at,
          'label', public.activity_label(l.action, l.old_values_json, l.new_values_json),
          'motif', nullif(l.new_values_json->>'motif', ''),
          'mandate_id', case when l.entity_type::text = 'mandate' then l.entity_id end,
          'reference', (select x.reference from mandates x where l.entity_type::text = 'mandate' and x.id = l.entity_id)) h
        from activity_logs l
        where coalesce(l.user_id, nullif(l.new_values_json->>'by', '')::uuid) = p_id
        order by l.created_at desc limit 100) t), '[]'::jsonb)
  );
end $$;

revoke all on function public.manager_detail(uuid) from public, anon;
grant execute on function public.manager_detail(uuid) to authenticated;
