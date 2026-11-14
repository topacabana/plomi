-- Recherche « tout champ » pour les barres de recherche des listes.
-- Chaque mot saisi doit apparaître quelque part (ordre libre, sans accents ni majuscules) ;
-- les numéros (téléphone, code postal, n° de dossier…) se trouvent même saisis avec espaces, points ou tirets.

create or replace function public.search_fold(p text)
returns text language sql immutable as $$
  select lower(translate(coalesce(p, ''),
    'ÀÁÂÃÄÅàáâãäåÇçÈÉÊËèéêëÌÍÎÏìíîïÑñÒÓÔÕÖòóôõöÙÚÛÜùúûüÝýÿ',
    'AAAAAAaaaaaaCcEEEEeeeeIIIIiiiiNnOOOOOoooooUUUUuuuuYyy'))
$$;

-- Vrai si tous les mots de p_query se trouvent dans p_haystack.
-- Tirets, apostrophes, points… séparent les mots (« Jean-Pierre » trouve « Jean Pierre ») ;
-- un mot composé de chiffres est cherché sans séparateurs (« 06 12 34 » trouve « 0612345678 »).
create or replace function public.search_match(p_haystack text, p_query text)
returns boolean language sql immutable as $$
  with h as (select regexp_replace(public.search_fold(p_haystack), '[^a-z0-9]+', ' ', 'g') t),
       h2 as (select replace(t, ' ', '') t from h)
  select coalesce(bool_and(
           case when w ~ '^[0-9]+$' then position(w in (select t from h2)) > 0
                else position(w in (select t from h)) > 0 end), true)
  from regexp_split_to_table(btrim(regexp_replace(public.search_fold(p_query), '[^a-z0-9]+', ' ', 'g')), ' ') w
  where w <> ''
$$;

-- Libellés français des statuts : public.mandate_status_label (existante) permet de chercher « attribué », « clôturé »…

-- Mandats de l'organisation correspondant à la recherche (toutes les colonnes du mandat,
-- bénéficiaire, assureur, n° de dossier assureur, expert attribué, fichier d'import)
create or replace function public.search_mandates(p_query text)
returns uuid[] language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(m.id), '{}')
    from mandates m
    left join beneficiaries b on b.id = m.beneficiary_id
    left join insurers i on i.id = m.insurer_id
    left join experts e on e.id = m.assigned_expert_id
    left join mandate_imports mi on mi.id = m.import_id
   where public.is_manager()
     and m.insurance_org_id = public.current_user_organization_id()
     and public.search_match(
           concat_ws(' ', (select string_agg(v, ' ') from jsonb_each_text(to_jsonb(m)) j(k, v)), public.mandate_status_label(m.status::text),
                     b.first_name, b.last_name, b.mobile_phone, b.landline_phone, b.email,
                     i.name, i.city, e.first_name, e.last_name, e.company_name, e.trade_name, e.phone, e.email,
                     mi.file_name),
           p_query)
$$;

-- Experts correspondant à la recherche (toutes les colonnes de la fiche, profils / agréments,
-- listes d'experts de l'organisation)
create or replace function public.search_experts(p_query text)
returns uuid[] language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(e.id), '{}')
    from experts_with_profiles e
   where public.is_manager()
     and public.search_match(
           concat_ws(' ', (select string_agg(v, ' ') from jsonb_each_text(to_jsonb(e)) j(k, v)),
                     (select string_agg(l.name, ' ') from expert_list_members lm join expert_lists l on l.id = lm.list_id
                       where lm.expert_id = e.id and l.organization_id = public.current_user_organization_id())),
           p_query)
$$;

revoke all on function public.search_mandates(text) from public, anon;
revoke all on function public.search_experts(text) from public, anon;
grant execute on function public.search_mandates(text) to authenticated;
grant execute on function public.search_experts(text) to authenticated;
