do $$ declare d text; begin
  d := pg_get_functiondef('public.expert_send_report(uuid,text,jsonb,text[],text)'::regprocedure);
  d := replace(d, $r$    if p_rooms is null or jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) = 0 then$r$,
                  $r$    if v_m.mandate_type::text <> 'visio' and (p_rooms is null or jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) = 0) then$r$);
  d := replace(d, $r$    for r in select * from jsonb_array_elements(p_rooms) loop$r$,
                  $r$    if v_m.mandate_type::text = 'visio' and nullif(trim(coalesce(p_conclusion,'')),'') is null then
        raise exception 'La conclusion est obligatoire pour une visio expertise';
    end if;
    for r in select * from jsonb_array_elements(coalesce(p_rooms, '[]'::jsonb)) loop$r$);
  execute d;
end $$;
