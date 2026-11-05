create table if not exists public.mandate_locks (
  mandate_id uuid primary key references public.mandates(id) on delete cascade,
  user_id    uuid not null,
  locked_at  timestamptz not null default now(),
  expires_at timestamptz not null
);
alter table public.mandate_locks enable row level security;
create policy "read locks" on public.mandate_locks for select to authenticated using (true);

create or replace function public.is_manager()
 returns boolean language sql stable security definer set search_path to 'public'
as $$ select exists (select 1 from public.user_profiles where id = auth.uid() and role::text = 'gestionnaire_assurance') $$;

create or replace function public.lock_holder_name(p_user uuid)
 returns text language sql stable security definer set search_path to 'public'
as $$ select coalesce(nullif(trim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')), ''), 'un autre gestionnaire')
        from public.user_profiles where id = p_user $$;

create or replace function public.lock_mandates(p_ids uuid[])
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_blocked jsonb := '[]'::jsonb; v_id uuid; v_l public.mandate_locks%rowtype;
begin
  if not public.is_manager() then return jsonb_build_object('blocked', v_blocked); end if;
  delete from public.mandate_locks where expires_at < now();
  foreach v_id in array coalesce(p_ids, '{}') loop
    select * into v_l from public.mandate_locks where mandate_id = v_id for update;
    if found and v_l.user_id <> auth.uid() then
      v_blocked := v_blocked || jsonb_build_object(
        'mandate_id', v_id,
        'reference', (select reference from public.mandates where id = v_id),
        'holder', public.lock_holder_name(v_l.user_id),
        'until', v_l.expires_at);
    else
      insert into public.mandate_locks (mandate_id, user_id, locked_at, expires_at)
      values (v_id, auth.uid(), now(), now() + interval '10 minutes')
      on conflict (mandate_id) do update set user_id = excluded.user_id, expires_at = excluded.expires_at;
    end if;
  end loop;
  return jsonb_build_object('blocked', v_blocked);
end $function$;

create or replace function public.release_mandates(p_ids uuid[])
 returns void language sql security definer set search_path to 'public'
as $$ delete from public.mandate_locks where mandate_id = any(coalesce(p_ids,'{}')) and user_id = auth.uid() $$;

grant execute on function public.is_manager() to authenticated;
grant execute on function public.lock_mandates(uuid[]) to authenticated;
grant execute on function public.release_mandates(uuid[]) to authenticated;

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.transition_mandate_status(uuid,mandate_status,uuid,text,assignment_type,uuid[])'::regprocedure);
  n := replace(d,
    $r$    v_allowed := case v_current$r$,
    $r$    -- Verrou gestionnaire (F17) : l'expert attribué / qui prend le mandat n'est jamais bloqué
    if public.is_manager()
       and not (public.current_expert_id() is not null
                and public.current_expert_id() in (coalesce(v_expert, '00000000-0000-0000-0000-000000000000'::uuid),
                                                  coalesce(p_expert_id, '00000000-0000-0000-0000-000000000000'::uuid))) then
        if exists (select 1 from public.mandate_locks
                    where mandate_id = p_mandate_id and user_id <> auth.uid() and expires_at > now()) then
            raise exception 'Mandat % en cours de traitement par %',
                (select reference from public.mandates where id = p_mandate_id),
                (select public.lock_holder_name(user_id) from public.mandate_locks where mandate_id = p_mandate_id);
        end if;
        insert into public.mandate_locks (mandate_id, user_id, locked_at, expires_at)
        values (p_mandate_id, auth.uid(), now(), now() + interval '10 minutes')
        on conflict (mandate_id) do update set user_id = excluded.user_id, expires_at = excluded.expires_at;
    end if;

    v_allowed := case v_current$r$);
  if n = d then raise exception 'motif introuvable'; end if;
  execute n;
end $mig$;
