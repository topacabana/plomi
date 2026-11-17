-- Supervision des gestionnaires : rôle superviseur + tableau de supervision temps réel
-- Le superviseur reste un gestionnaire (role = gestionnaire_assurance) : le droit est un drapeau
-- attribuable plus tard à un adjoint sans toucher au code.

alter table public.user_profiles
  add column if not exists is_supervisor boolean not null default false;

update public.user_profiles set is_supervisor = true where email = 'cadelisthomas7@gmail.com';

create or replace function public.is_supervisor()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_profiles
                 where id = auth.uid() and role::text = 'gestionnaire_assurance' and is_supervisor)
$$;

-- Libellé lisible d'une ligne d'historique
create or replace function public.activity_label(p_action text, p_old jsonb, p_new jsonb)
returns text language sql immutable as $$
  select case p_action
    when 'status_transition' then
      case p_new->>'status'
        when 'dropped' then 'Mis sur la carte'
        when 'redrop' then 'Redrop'
        when 'drop_pending' then 'Renvoyé en liste de drop'
        when 'assigned' then 'Attribué à un expert'
        when 'suspended' then 'Mis en pause'
        when 'closed' then case when p_new->>'closure_type' = 'without_follow_up' then 'Clôture sans suite' else 'Clôturé' end
        when 'cancelled' then 'Annulé'
        else public.mandate_status_label(p_old->>'status') || ' → ' || public.mandate_status_label(p_new->>'status')
      end
    when 'mandate_created' then 'Mandat créé'
    when 'mandate_updated' then 'Mandat modifié'
    when 'report_validated' then 'Rapport validé'
    when 'manual_assignment' then 'Attribution manuelle'
    when 'expert_list_created' then 'Liste d''experts créée'
    when 'group_message' then 'Message groupé'
    when 'mandates_pdf_export' then 'Export PDF'
    when 'stats_report_downloaded' then 'Rapport de stats téléchargé'
    when 'profile_updated' then 'Profil modifié'
    when 'user_login' then 'Connexion'
    when 'redrop' then 'Redrop'
    when 'drop_simple' then 'Mis sur la carte'
    when 'drop_list' then 'Diffusé à une liste'
    when 'mandate_withdrawn_from_cloud' then 'Retiré de la carte'
    when 'document_uploaded' then 'Document ajouté'
    when 'report_submitted' then 'Rapport déposé'
    when 'assignment_accepted' then 'Attribution acceptée'
    when 'assignment_refused' then 'Attribution refusée'
    when 'archive_viewed' then 'Archive consultée'
    else replace(p_action, '_', ' ')
  end
$$;

create or replace function public.supervision_dashboard()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_org uuid;
  v_day timestamptz := date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris';
  v_30 timestamptz := now() - interval '30 days';
begin
  if not public.is_supervisor() then
    raise exception 'Accès réservé au superviseur' using errcode = '42501';
  end if;
  select organization_id into v_org from user_profiles where id = auth.uid();

  return coalesce((
    with mgr as (
      select u.id, u.first_name, u.last_name, u.email, u.is_supervisor, u.last_seen_at, u.presence_status::text presence_status,
             coalesce(au.raw_user_meta_data->>'avatar_url', au.raw_user_meta_data->>'picture', au.raw_user_meta_data->>'photo_url') photo_url
      from user_profiles u left join auth.users au on au.id = u.id
      where u.organization_id = v_org and u.role::text = 'gestionnaire_assurance'
    ),
    logs as (
      select coalesce(a.user_id, nullif(a.new_values_json->>'by', '')::uuid) actor, a.*
      from activity_logs a
      where a.created_at >= v_30
    )
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'name', trim(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')),
      'initials', upper(left(coalesce(m.first_name, '?'), 1) || left(coalesce(m.last_name, ''), 1)),
      'email', m.email,
      'photo_url', m.photo_url,
      'is_supervisor', m.is_supervisor,
      'is_me', m.id = auth.uid(),
      'online', coalesce(m.last_seen_at > now() - interval '5 minutes', false),
      'last_seen_at', m.last_seen_at,
      'today', jsonb_build_object(
        'actions', (select count(*) from logs l where l.actor = m.id and l.created_at >= v_day),
        'created', (select count(*) from mandates x where x.created_by_user_id = m.id and x.created_at >= v_day),
        'drops', (select count(*) from logs l where l.actor = m.id and l.created_at >= v_day and l.action = 'status_transition' and l.new_values_json->>'status' in ('dropped', 'redrop')),
        'assignments', (select count(*) from logs l where l.actor = m.id and l.created_at >= v_day and l.action = 'status_transition' and l.new_values_json->>'status' = 'assigned')
      ),
      'load', jsonb_build_object(
        'open', (select count(*) from mandates x where x.created_by_user_id = m.id and x.status::text not in ('closed', 'cancelled')),
        'reports', (select count(*) from mandates x where x.created_by_user_id = m.id and x.status::text = 'waiting_report'),
        'locks', (select count(*) from mandate_locks k where k.user_id = m.id and k.expires_at > now())
      ),
      'quality', jsonb_build_object(
        'avg_assign_hours', (select round((extract(epoch from avg(x.assigned_at - x.created_at)) / 3600)::numeric, 1)
                             from mandates x where x.created_by_user_id = m.id and x.assigned_at is not null and x.created_at >= v_30),
        'redrops', (select count(*) from logs l where l.actor = m.id and l.action = 'status_transition' and l.new_values_json->>'status' = 'redrop'),
        'closed', (select count(*) from logs l where l.actor = m.id and l.action = 'status_transition' and l.new_values_json->>'status' = 'closed'),
        'sans_suite', (select count(*) from logs l where l.actor = m.id and l.action = 'status_transition' and l.new_values_json->>'status' = 'closed' and l.new_values_json->>'closure_type' = 'without_follow_up')
      ),
      'history', coalesce((
        select jsonb_agg(h order by h->>'at' desc) from (
          select jsonb_build_object(
            'at', l.created_at,
            'label', public.activity_label(l.action, l.old_values_json, l.new_values_json),
            'mandate_id', case when l.entity_type::text = 'mandate' then l.entity_id end,
            'reference', (select x.reference from mandates x where l.entity_type::text = 'mandate' and x.id = l.entity_id)
          ) h
          from activity_logs l
          where coalesce(l.user_id, nullif(l.new_values_json->>'by', '')::uuid) = m.id
          order by l.created_at desc limit 5
        ) t), '[]'::jsonb)
    ) order by m.is_supervisor, m.last_name)
    from mgr m
  ), '[]'::jsonb);
end $$;

revoke all on function public.supervision_dashboard() from public, anon;
grant execute on function public.supervision_dashboard() to authenticated;
grant execute on function public.is_supervisor() to authenticated;
