// PLOMI — travel-times : temps de trajet en voiture (Google Routes API) adresse de l'expert -> adresse du mandat.
// Appelée toutes les 15 min par pg_cron avec { token } (jeton vérifié en base, dans le coffre Vault).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
const ll = (s: string) => { const [a, b] = s.split(",").map(Number); return { location: { latLng: { latitude: a, longitude: b } } }; };

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);
  const { token } = await req.json().catch(() => ({}));
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await db.rpc("travel_pending", { p_token: token ?? "", p_limit: 25 });
  if (error) return json({ error: error.message }, 403);
  const key: string = data?.key;
  const items: { id: string; from: string; to: string; expert_id: string }[] = data?.items ?? [];
  let ok = 0, ko = 0, denied: string | null = null;
  for (const it of items) {
    const res = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key, "X-Goog-FieldMask": "routes.duration,routes.distanceMeters" },
      body: JSON.stringify({ origin: ll(it.from), destination: ll(it.to), travelMode: "DRIVE", languageCode: "fr-FR" }),
    }).catch((e) => ({ ok: false, status: 0, json: async () => ({ error: { message: String(e) } }) } as unknown as Response));
    const r = await res.json().catch(() => ({}));
    if (!res.ok) {
      if ([401, 403, 429, 0].includes(res.status)) { denied = `${res.status} : ${r?.error?.message ?? ""}`; break; }
      await db.rpc("travel_save", { p_token: token, p_mandate_id: it.id, p_expert_id: it.expert_id, p_minutes: null, p_km: null, p_error: `${res.status} ${r?.error?.message ?? ""}`.slice(0, 300) });
      ko++; continue;
    }
    const route = r?.routes?.[0];
    if (route?.duration) {
      const sec = parseInt(String(route.duration).replace("s", ""), 10);
      await db.rpc("travel_save", { p_token: token, p_mandate_id: it.id, p_expert_id: it.expert_id,
        p_minutes: Math.round(sec / 60), p_km: Math.round((route.distanceMeters ?? 0) / 100) / 10, p_error: null });
      ok++;
    } else {
      await db.rpc("travel_save", { p_token: token, p_mandate_id: it.id, p_expert_id: it.expert_id, p_minutes: null, p_km: null, p_error: "Aucun itinéraire" });
      ko++;
    }
  }
  return json({ pending: items.length, computed: ok, failed: ko, error: denied });
});
