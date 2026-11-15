// Fonction retirée le 15/11/2026 (audit RGPD, action B5).
// Remplacée par invite-expert (création d'expert avec contrôle de rôle) et par le
// géocodage serveur Géoplateforme IGN (geocode-addresses). Elle n'envoie plus
// aucune adresse à Nominatim et ne crée plus de compte : elle répond 410 Gone.
Deno.serve(() =>
  new Response(JSON.stringify({ error: "Fonction retirée", replaced_by: "invite-expert" }), {
    status: 410,
    headers: { "Content-Type": "application/json" },
  })
);
