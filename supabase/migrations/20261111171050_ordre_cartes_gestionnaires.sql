-- Ordre personnalisé des cartes gestionnaires (glisser-déposer), propre à chaque superviseur
alter table public.user_profiles add column if not exists dashboard_card_order uuid[];

create or replace function public.save_dashboard_card_order(p_order uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Utilisateur non connecté'; end if;
  update user_profiles set dashboard_card_order = p_order where id = auth.uid();
end $$;
revoke all on function public.save_dashboard_card_order(uuid[]) from public, anon;
grant execute on function public.save_dashboard_card_order(uuid[]) to authenticated;

-- supervision_dashboard renvoie les cartes dans l'ordre enregistré (les nouvelles à la fin)
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.supervision_dashboard'::regproc);
  if position('dashboard_card_order' in d) = 0 then
    n := regexp_replace(d, 'declare\s+v_org\s+uuid\s*;', E'declare v_org uuid; v_order uuid[];');
    n := regexp_replace(n, '(select\s+organization_id\s+into\s+v_org\s+from\s+user_profiles\s+where\s+id\s*=\s*auth\.uid\(\)\s*;)',
      E'\\1\n  select dashboard_card_order into v_order from user_profiles where id = auth.uid();');
    n := regexp_replace(n, 'order\s+by\s+m\.is_supervisor\s*,\s*m\.last_name', 'order by array_position(v_order, m.id) nulls last, m.is_supervisor, m.last_name');
    if position('array_position(v_order' in n) = 0 or position('v_order uuid[]' in n) = 0 then
      raise exception 'ancres supervision_dashboard introuvables';
    end if;
    execute n;
  end if;
end $$;
