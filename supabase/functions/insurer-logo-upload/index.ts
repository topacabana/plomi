// PLOMI — insurer-logo-upload
// Reçoit le logo choisi dans un champ fichier natif WeWeb (base64 ou data URI) et le range
// dans le bucket public "insurer-logos", dossier de l'organisation de l'utilisateur.
// Appel : POST { file_name, content_base64 }  (JWT de l'utilisateur obligatoire)
// Réponse : 200 { ok: true, url } ou 200 { ok: false, error } (refus lisibles par un workflow natif).
// Accès : l'envoi se fait avec les droits de l'utilisateur, donc la règle de stockage
// « insurer-logos : envoi par un gestionnaire » (is_manager + dossier de l'organisation) s'applique.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const refuse = (error: string) => json({ ok: false, error });

const MAX_BYTES = 2 * 1024 * 1024;
const TYPES: Record<string, string> = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", svg: "image/svg+xml" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const raw = String(body.content_base64 ?? "");
    if (!raw) return refuse("Aucun fichier reçu.");

    // Type : celui du data URI s'il est fourni, sinon l'extension du nom de fichier
    const m = raw.match(/^data:([^;,]+);base64,(.*)$/s);
    const ext = String(body.file_name ?? "").split(".").pop()?.toLowerCase() ?? "";
    const type = m ? m[1].toLowerCase() : (TYPES[ext] ?? "");
    const extOut = Object.entries(TYPES).find(([, t]) => t === type)?.[0];
    if (!extOut) return refuse("Format non accepté : PNG, JPEG, WebP ou SVG uniquement.");

    let bytes: Uint8Array;
    try {
      bytes = Uint8Array.from(atob((m ? m[2] : raw).replace(/\s/g, "")), (c) => c.charCodeAt(0));
    } catch {
      return refuse("Fichier illisible.");
    }
    if (bytes.length === 0) return refuse("Fichier vide.");
    if (bytes.length > MAX_BYTES) return refuse("Logo trop lourd : 2 Mo maximum.");

    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: u } = await asUser.auth.getUser();
    if (!u?.user) return json({ ok: false, error: "Utilisateur non connecté" }, 401);

    const { data: orgId, error: orgError } = await asUser.rpc("current_user_organization_id");
    if (orgError || !orgId) return refuse("Organisation introuvable.");

    const path = `${orgId}/${crypto.randomUUID()}.${extOut}`;
    const { error } = await asUser.storage.from("insurer-logos").upload(path, bytes, { contentType: type, upsert: false });
    if (error) return refuse("Envoi impossible : " + error.message);

    const { data } = asUser.storage.from("insurer-logos").getPublicUrl(path);
    return json({ ok: true, url: data.publicUrl });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message ?? e) }, 500);
  }
});
