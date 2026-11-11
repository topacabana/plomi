-- Suppression du champ « réseau disponible » (cases 3G / 4G retirées de la page de création).
-- Validé par Thomas le 11/11/2026 : 16 valeurs existantes perdues. Les 10 collections WeWeb ont été décochées avant.
-- Les 3 vues qui exposaient la colonne sont recréées à l'identique sans elle (options security_invoker conservées),
-- puis la fonction d'enregistrement du formulaire ne l'accepte plus.

do $do$
declare
  v record;
  d text;
begin
  for v in
    select c.relname, c.reloptions, pg_get_viewdef(c.oid, true) as def
      from pg_class c
     where c.relnamespace = 'public'::regnamespace
       and c.relname in ('pending_mandates_with_beneficiaries', 'my_active_mandates', 'available_mandates_for_expert')
  loop
    d := regexp_replace(v.def, '\n\s*(m\.)?network_available,', '', 'g');
    if d = v.def then raise exception 'Vue % : colonne network_available introuvable', v.relname; end if;
    execute format('drop view public.%I', v.relname);
    execute format('create view public.%I %s as %s',
                   v.relname,
                   case when v.reloptions is null then '' else 'with (' || array_to_string(v.reloptions, ', ') || ')' end,
                   d);
    execute format('grant select on public.%I to authenticated, service_role', v.relname);
  end loop;
end $do$;

do $do$
declare d text := pg_get_functiondef('public.save_mandate_form(uuid, jsonb, boolean, uuid[], boolean)'::regprocedure);
begin
  if position('''network_available'',' in d) = 0 then raise exception 'save_mandate_form : ancre introuvable'; end if;
  d := replace(d, '''network_available'',', '');
  execute d;
end $do$;

alter table public.mandates drop column network_available;
