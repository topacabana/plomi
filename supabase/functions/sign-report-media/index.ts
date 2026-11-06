// PLOMI — sign-report-media
// Le bucket "documents" est privé : renvoie, pour les rapports d'un mandat, des liens
// signés temporaires (1 h) vers les photos, indexés par le lien enregistré en base.
// Appel : POST { "mandate_id": "<uuid>" }  (JWT de l'utilisateur obligatoire)
// Accès : décidé par la sécurité de la base (RLS) — on lit les rapports avec les droits
// de l'utilisateur : gestionnaire de l'organisation du mandat, ou expert auteur du rapport.
// v2 : inclut aussi les médias de l'éditeur (table report_media, CC L/M).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const storagePath = (u: string) => {
  const m = String(u ?? "").split("?")[0].match(/\/storage\/v1\/object\/(?:public|sign|authenticated)\/documents\/(.+)$/);
  return m ? decodeURIComponent(m[1]) : null;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);
  try {
    const { mandate_id } = await req.json().catch(() => ({}));
    if (!mandate_id) return json({ error: "mandate_id manquant" }, 400);
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: u } = await asUser.auth.getUser();
    if (!u?.user?.id) return json({ error: "Utilisateur non connecté" }, 401);

    // Lecture avec les droits de l'utilisateur : la RLS ne renvoie que ce qu'il a le droit de voir
    const { data: rooms, error } = await asUser.from("rdf_report_rooms").select("photos").eq("mandate_id", mandate_id);
    if (error) return json({ error: error.message }, 500);
    const { data: reps } = await asUser.from("rdf_reports").select("inspection_photos,colorant_photos,gaz_traceur_photos,sonde_photos").eq("mandate_id", mandate_id);
    const { data: med } = await asUser.from("report_media").select("file_url").eq("mandate_id", mandate_id);

    const all = new Set<string>();
    for (const r of rooms ?? []) for (const p of r.photos ?? []) all.add(p);
    for (const r of reps ?? []) for (const k of ["inspection_photos", "colorant_photos", "gaz_traceur_photos", "sonde_photos"]) for (const p of (r as any)[k] ?? []) all.add(p);
    for (const m of med ?? []) if (m.file_url) all.add(m.file_url);

    const urls: Record<string, string> = {};
    const paths: string[] = [], origin: string[] = [];
    for (const p of all) { const sp = storagePath(p); if (sp) { paths.push(sp); origin.push(p); } }
    if (paths.length) {
      const { data: signed } = await admin.storage.from("documents").createSignedUrls(paths, 3600);
      (signed ?? []).forEach((s: any, i: number) => { if (s?.signedUrl) urls[origin[i]] = s.signedUrl; });
    }
    return json({ urls, count: Object.keys(urls).length });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
