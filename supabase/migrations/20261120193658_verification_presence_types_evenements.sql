-- Types d'événements de la vérification de présence dans le journal des experts (trouvé par la CI, test pgTAP 12).
alter table public.expert_performance_logs drop constraint if exists expert_performance_logs_event_type_check;
alter table public.expert_performance_logs add constraint expert_performance_logs_event_type_check check (event_type = any (array[
  'mandate_assigned', 'mandate_accepted', 'mandate_refused', 'mandate_expired', 'mandate_completed', 'redrop_caused',
  'intervention_started', 'intervention_completed', 'report_submitted', 'report_validated', 'report_rejected',
  'arrived_on_site', 'expert_suspended', 'expert_reinstated',
  'presence_code_sent', 'presence_verified', 'presence_locked'
]::text[]));
