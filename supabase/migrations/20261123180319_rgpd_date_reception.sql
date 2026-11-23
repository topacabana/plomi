-- Registre RGPD : la date saisie est la date de RÉCEPTION (échéance = +1 mois, calculée).
-- Une date de réception future ou de plus d'un an est refusée.
create or replace function public.rgpd_request_add(p_type text, p_subject_label text, p_channel text default null::text,
  p_received_at date default current_date, p_subject_id uuid default null::uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare v_id uuid; v_recu date := coalesce(p_received_at, current_date);
begin
  if not public.is_supervisor() then raise exception 'Réservé au superviseur' using errcode = '42501'; end if;
  if p_type not in ('acces', 'effacement', 'rectification', 'opposition', 'limitation', 'portabilite', 'autre') then
    return jsonb_build_object('ok', false, 'error', 'Type de demande inconnu.');
  end if;
  if v_recu > current_date then
    return jsonb_build_object('ok', false, 'error', 'La date de réception ne peut pas être dans le futur (l''échéance d''un mois est calculée à partir d''elle).');
  end if;
  if v_recu < current_date - interval '1 year' then
    return jsonb_build_object('ok', false, 'error', 'Date de réception trop ancienne (plus d''un an).');
  end if;
  insert into rgpd_requests (organization_id, request_type, subject_id, subject_label, channel, received_at, due_at)
  values (public.current_user_organization_id(), p_type, p_subject_id, nullif(btrim(p_subject_label), ''),
          nullif(btrim(p_channel), ''), v_recu, (v_recu + interval '1 month')::date)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'due_at', (v_recu + interval '1 month')::date);
end $function$;
