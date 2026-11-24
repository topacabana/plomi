-- Aligne le nom du profil utilisateur sur celui de la fiche expert (source affichée par experts_with_profiles).
update public.user_profiles p set first_name = e.first_name, last_name = e.last_name
from public.experts e where e.user_id = p.id
  and (p.first_name is distinct from e.first_name or p.last_name is distinct from e.last_name);
