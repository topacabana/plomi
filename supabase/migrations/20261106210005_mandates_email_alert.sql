-- Préférence de communication du client : SMS et/ou e-mail (cochables ensemble)
alter table public.mandates add column if not exists email_alert_enabled boolean not null default false;
comment on column public.mandates.sms_alert_enabled is 'Le client souhaite être prévenu par SMS';
comment on column public.mandates.email_alert_enabled is 'Le client souhaite être prévenu par e-mail';

do $$
declare v_def text;
begin
  select pg_get_functiondef('public.save_mandate_form(uuid,jsonb,boolean,uuid[],boolean)'::regprocedure) into v_def;
  if position('''email_alert_enabled''' in v_def) = 0 then
    v_def := replace(v_def, '''sms_alert_enabled'',', '''sms_alert_enabled'',''email_alert_enabled'',');
    execute v_def;
  end if;
end $$;
