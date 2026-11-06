do $$ declare d text; f text; begin
  foreach f in array array['public.recruitment_fiche(uuid)','public.recruitment_expert_stats(uuid,date,date,text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    d := replace(d, 'values (auth.uid(), ''expert'', p_expert_id', 'values (auth.uid(), ''broadcast'', p_expert_id');
    execute d;
  end loop;
end $$;
