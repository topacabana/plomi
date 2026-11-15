// PLOMI — Géocodage des adresses (mandats, experts, assureurs et villes centres de zone de chalandise).
// Service : Géoplateforme IGN (Base Adresse Nationale), gratuit, sans clé, hébergé en France.
// Appelée par pg_net (trigger à l'insertion / changement d'adresse) et par pg_cron toutes les 15 min.
// Sécurité : verify_jwt = false, mais le corps doit porter le jeton du coffre Vault (travel_cron_token),
// vérifié côté base par geocode_pending / geocode_save_place.
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const MIN_SCORE = 0.5; // en dessous, l'adresse est jugée trop incertaine pour être placée sur la carte

type Item = { kind: "mandate" | "expert" | "insurer" | "insurer_zone"; id: string; q: string; type: string | null };

// Nettoie la requête : la Géoplateforme refuse (HTTP 400) les puces, tirets ou symboles en tête
// et les requêtes de plus de 200 caractères.
const clean = (q: string) => q.replace(/[^\p{L}\p{N}'’,.\- ]+/gu, " ").replace(/\s+/g, " ").replace(/^[^\p{L}\p{N}]+/u, "").trim().slice(0, 200);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  let token = "";
  try { token = (await req.json())?.token ?? ""; } catch { /* corps vide */ }
  if (!token) return json({ error: "Jeton manquant" }, 401);

  const { data, error } = await db.rpc("geocode_pending", { p_token: token, p_limit: 25 });
  if (error) return json({ error: error.message }, 401);
  const items: Item[] = data?.items ?? [];

  const results: Record<string, unknown>[] = [];
  for (const it of items) {
    let lat: number | null = null, lng: number | null = null, postcode: string | null = null, err: string | null = null;
    try {
      const q = clean(it.q);
      const params = new URLSearchParams({ q, limit: "1", index: "address" });
      if (it.type) params.set("type", it.type);
      const r = q.length >= 3 ? await fetch("https://data.geopf.fr/geocodage/search?" + params, { signal: AbortSignal.timeout(8000) }) : null;
      // 5xx ou réseau : service indisponible (on réessaiera). 4xx : c'est l'adresse qui pose problème.
      if (r && r.status >= 500) throw new Error("HTTP " + r.status);
      const f = r && r.ok ? (await r.json())?.features?.[0] : null;
      if (!f) err = r && !r.ok ? `Adresse refusée par le service (HTTP ${r.status})` : "Adresse non localisée";
      else if ((f.properties?.score ?? 0) < MIN_SCORE) err = `Adresse imprécise (score ${Number(f.properties.score).toFixed(2)})`;
      else {
        [lng, lat] = f.geometry.coordinates;
        postcode = f.properties?.postcode ?? null;
      }
    } catch (e) {
      // Service indisponible : on n'écrit rien, le prochain passage (15 min) réessaiera, et on s'arrête.
      results.push({ kind: it.kind, id: it.id, ok: false, error: "Géoplateforme indisponible : " + (e as Error).message });
      break;
    }
    const { error: saveErr } = await db.rpc("geocode_save_place", {
      p_token: token, p_kind: it.kind, p_id: it.id, p_lat: lat, p_lng: lng, p_postcode: postcode, p_error: err,
    });
    results.push({ kind: it.kind, id: it.id, ok: !err, error: err ?? saveErr?.message ?? null });
  }
  return json({ processed: results.length, results });
});
