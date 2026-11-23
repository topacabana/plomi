// PLOMI — mandate-completion
// Complétion d'un mandat importé sans rendez-vous, par le client lui-même.
//
// POST { "action": "request", "mandate_id": "<uuid>" }          (JWT du gestionnaire obligatoire)
//   → manager_completion_prepare (droits vérifiés en base) tire un jeton à usage unique (7 jours) et
//     l'e-mail Brevo envoie au bénéficiaire le lien <app gestionnaire>/completer-dossier?t=<jeton>.
// POST { "action": "get", "token": "..." }                       (public, page client)
// POST { "action": "submit", "token": "...", "payload": {...} }  (public, page client)
//   → completion_get / completion_submit, réservées à la clé service : toutes les règles
//     (3 créneaux distincts, 12 h à l'avance, 3 mois, 7 h–20 h, rappel, champs vides seulement) sont en base.
//
// Sécurité : verify_jwt = false car la page client n'a pas de compte ; le jeton client n'est jamais stocké
// en clair (hash SHA-256). Pour « request », l'utilisateur est vérifié dans le jeton Supabase.
// L'adresse de l'application est lue dans l'en-tête Origin (posé par le navigateur) puis figée dans
// app_settings.manager_app_origin ; une origine d'éditeur WeWeb n'est jamais utilisée pour le lien.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const PAGE_PATH = "completer-dossier";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

const frame = (title: string, body: string) => `<!doctype html><html lang="fr"><body style="margin:0;background:#f4f5f7;font-family:Arial,Helvetica,sans-serif;color:#1f2937">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" style="max-width:520px;background:#ffffff;border:1px solid #e5e7eb;border-radius:12px" cellpadding="0" cellspacing="0">
<tr><td style="padding:24px 24px 8px"><div style="font-size:13px;color:#1e3a8a;font-weight:bold;letter-spacing:.5px">PLOMI</div>
<h1 style="font-size:20px;margin:8px 0 0;color:#1e3a8a">${title}</h1></td></tr>
<tr><td style="padding:8px 24px 24px;font-size:15px;line-height:1.5">${body}</td></tr></table>
<p style="font-size:12px;color:#6b7280;max-width:520px">Message automatique envoyé par PLOMI pour le compte de votre assureur. Merci de ne pas y répondre.</p>
</td></tr></table></body></html>`;

async function sendMail(to: string, toName: string, subject: string, html: string, text: string) {
  const key = Deno.env.get("BREVO_API_KEY");
  if (!key) throw new Error("Envoi d'e-mail non configuré (BREVO_API_KEY manquante)");
  const r = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": key, "Content-Type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: { email: Deno.env.get("BREVO_SENDER_EMAIL") ?? "noreply@plomi.fr", name: Deno.env.get("BREVO_SENDER_NAME") ?? "PLOMI" },
      to: [{ email: to, name: toName || undefined }],
      subject, htmlContent: html, textContent: text, tags: ["plomi", "completion"],
    }),
  });
  if (!r.ok) throw new Error(`Brevo a refusé l'envoi (${r.status}) : ${(await r.text()).slice(0, 200)}`);
}

// deno-lint-ignore no-explicit-any
async function appOrigin(admin: any, req: Request): Promise<string | null> {
  const o = (req.headers.get("origin") ?? "").replace(/\/+$/, "");
  const usable = /^https:\/\/[a-z0-9.-]+$/i.test(o) && !/editor/i.test(o);
  const { data } = await admin.from("app_settings").select("value").eq("key", "manager_app_origin").maybeSingle();
  const pinned = typeof data?.value === "string" ? data.value : null;
  if (pinned) return pinned;
  if (!usable) return null;
  await admin.from("app_settings").upsert({ key: "manager_app_origin", value: o, updated_at: new Date().toISOString() });
  return o;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const body = await req.json().catch(() => ({}));
    const { action } = body ?? {};

    if (action === "get" || action === "submit") {
      const token = String(body.token ?? "");
      if (!/^[A-Za-z0-9_-]{20,64}$/.test(token)) return json({ ok: false, error: "Lien invalide" });
      const { data, error } = action === "get"
        ? await admin.rpc("completion_get", { p_token: token })
        : await admin.rpc("completion_submit", { p_token: token, p_payload: body.payload ?? {} });
      if (error) return json({ ok: false, error: "Le service est momentanément indisponible, réessayez plus tard." }, 500);
      return json(data);
    }

    if (action !== "request" || !body.mandate_id) return json({ ok: false, error: "Paramètres invalides" }, 400);
    if (!Deno.env.get("BREVO_API_KEY")) return json({ ok: false, error: "Envoi d'e-mail non configuré" }, 503);
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: u } = await asUser.auth.getUser();
    if (!u?.user?.id) return json({ ok: false, error: "Utilisateur non connecté" }, 401);

    const origin = await appOrigin(admin, req);
    if (!origin) return json({ ok: false, error: "Envoyez la demande depuis l'application publiée (pas depuis l'éditeur)." }, 400);

    // Préparation avec les droits du gestionnaire : organisation, statut, e-mail, anti-doublon (2 min) vérifiés en base
    const { data: r, error } = await asUser.rpc("manager_completion_prepare", { p_mandate_id: body.mandate_id });
    if (error) return json({ ok: false, error: error.message }, 400);

    const link = `${origin}/${PAGE_PATH}?t=${encodeURIComponent(r.token)}`;
    const by = r.insurer ? `${r.organization} pour le compte de ${r.insurer}` : String(r.organization ?? "votre assureur");
    const ref = r.insurer_file_number ? `dossier ${r.insurer_file_number}` : `dossier ${r.reference}`;
    const html = frame("Choisissez vos disponibilités", `
<p>Bonjour ${esc(r.first_name)},</p>
<p>${esc(by)} a missionné un expert pour votre sinistre (${esc(ref)}) au <b>${esc(r.address)}</b>.</p>
<p>Pour organiser sa visite, merci d'indiquer <b>3 créneaux</b> qui vous conviennent et de compléter les informations manquantes. Si vous préférez, vous pouvez aussi demander à être rappelé.</p>
<p style="text-align:center;margin:24px 0"><a href="${esc(link)}" style="background:#1e3a8a;color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:bold;display:inline-block">Compléter mon dossier</a></p>
<p style="font-size:13px;color:#6b7280">Ce lien est personnel et valable 7 jours. Si le bouton ne fonctionne pas, copiez cette adresse dans votre navigateur :<br>${esc(link)}</p>
<p>Cordialement,<br>${esc(r.organization ?? "L'équipe PLOMI")}</p>`);
    const text = `Bonjour ${r.first_name ?? ""},\n\n${by} a missionné un expert pour votre sinistre (${ref}) au ${r.address}.\n`
      + `Merci d'indiquer 3 créneaux et de compléter les informations manquantes, ou de demander à être rappelé :\n${link}\n\n`
      + `Ce lien est personnel et valable 7 jours.\n\nCordialement,\n${r.organization ?? "L'équipe PLOMI"}`;
    try {
      await sendMail(r.email, `${r.first_name ?? ""} ${r.last_name ?? ""}`.trim(), `Votre ${ref} : choisissez vos disponibilités`, html, text);
    } catch (e) {
      // Envoi raté : le lien n'est pas parti, on l'annule et le mandat redevient « incomplet »
      await admin.from("mandate_completion_tokens").update({ expires_at: new Date().toISOString() })
        .eq("mandate_id", body.mandate_id).is("used_at", null);
      await admin.from("mandates").update({ completion_status: "incomplete", completion_requested_at: null }).eq("id", body.mandate_id);
      return json({ ok: false, error: (e as Error).message }, 502);
    }
    const [user, dom] = String(r.email).split("@");
    return json({ ok: true, sent_to: `${(user ?? "").slice(0, 1)}•••@${dom ?? ""}` });
  } catch (e) {
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
