-- La vue des verrous de mandats n'est utile qu'aux utilisateurs connectés.
-- Le rôle anon (pages publiques : connexion, mot de passe oublié) n'y a plus accès.
revoke all on public.mandate_lock_status from anon;
