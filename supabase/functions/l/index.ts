// PLOMI — l : résolution des liens courts (table short_links).
// GET /functions/v1/l?c=<code>  → redirection 302 vers un lien signé de 10 minutes du fichier.
// verify_jwt = false : le lien est ouvert depuis un mail, sans session ; le code (10 caractères
// aléatoires, ~59 bits) et l'expiration à 7 jours font office de contrôle d'accès, comme le lien signé.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const page = (msg: string, status: number) =>
  new Response(
    `<!doctype html><meta charset="utf-8"><title>PLOMI</title><body style="font-family:system-ui;padding:40px;color:#1e3a8a"><h2>PLOMI</h2><p>${msg}</p></body>`,
    { status, headers: { "Content-Type": "text/html; charset=utf-8" } },
  );

Deno.serve(async (req) => {
  const code = new URL(req.url).searchParams.get("c") ?? "";
  if (!/^[A-Za-z0-9]{10}$/.test(code)) return page("Lien invalide.", 400);
  const { data: link } = await admin.from("short_links").select("bucket,path,file_name,expires_at").eq("code", code).maybeSingle();
  if (!link) return page("Lien introuvable.", 404);
  if (new Date(link.expires_at) < new Date()) return page("Ce lien a expiré (validité 7 jours). Demandez un nouvel envoi.", 410);
  const { data: signed, error } = await admin.storage.from(link.bucket)
    .createSignedUrl(link.path, 600, link.file_name ? { download: link.file_name } : undefined);
  if (error || !signed) return page("Fichier indisponible.", 404);
  return new Response(null, { status: 302, headers: { Location: signed.signedUrl, "Cache-Control": "no-store" } });
});
