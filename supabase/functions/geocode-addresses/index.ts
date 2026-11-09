// PLOMI — Géocodage Google des adresses (mandats et experts).
// Appelée par pg_net (trigger à l'insertion / changement d'adresse) et par pg_cron toutes les 15 min.
// Sécurité : verify_jwt = false, mais le corps doit porter le jeton du coffre Vault (travel_cron_token),
// vérifié côté base par geocode_pending / geocode_save.
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

type Item = { kind: "mandate" | "expert"; id: string; address: string };

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  let token = "";
  try { token = (await req.json())?.token ?? ""; } catch { /* corps vide */ }
  if (!token) return json({ error: "Jeton manquant" }, 401);

  const { data, error } = await db.rpc("geocode_pending", { p_token: token, p_limit: 25 });
  if (error) return json({ error: error.message }, 401);

  const key: string = data?.key ?? "";
  const items: Item[] = data?.items ?? [];
  if (!key) return json({ error: "Clé Google absente du coffre" }, 500);

  const results: Record<string, unknown>[] = [];
  for (const it of items) {
    let lat: number | null = null, lng: number | null = null, err: string | null = null;
    try {
      const url = "https://maps.googleapis.com/maps/api/geocode/json?region=fr&language=fr&components=country:FR"
        + "&address=" + encodeURIComponent(it.address) + "&key=" + key;
      const r = await fetch(url);
      const g = await r.json();
      if (g.status === "OK" && g.results?.length) {
        lat = g.results[0].geometry.location.lat;
        lng = g.results[0].geometry.location.lng;
      } else if (g.status === "REQUEST_DENIED") {
        err = "API Geocoding non activée ou clé refusée : " + (g.error_message ?? "");
      } else if (g.status === "ZERO_RESULTS") {
        err = "Adresse non localisée";
      } else {
        err = "Google : " + g.status + (g.error_message ? " — " + g.error_message : "");
      }
    } catch (e) {
      err = "Erreur réseau : " + (e as Error).message;
    }
    // Clé refusée (API ou facturation non activée) : problème de configuration, pas d'adresse.
    // On n'écrit rien pour que le prochain passage (15 min) réessaie, et on s'arrête.
    if (err?.startsWith("API Geocoding")) {
      results.push({ kind: it.kind, id: it.id, ok: false, error: err });
      break;
    }
    const { error: saveErr } = await db.rpc("geocode_save", {
      p_token: token, p_kind: it.kind, p_id: it.id, p_lat: lat, p_lng: lng, p_error: err,
    });
    results.push({ kind: it.kind, id: it.id, ok: !err, error: err ?? saveErr?.message ?? null });
  }
  return json({ processed: results.length, results });
});
