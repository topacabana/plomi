// PLOMI — presence-verification
// Vérifie que la personne qui se présente chez le bénéficiaire est bien l'expert mandaté.
//
// POST { "action": "request", "mandate_id": "<uuid>" }
//   → tire un code à 6 chiffres (en base, presence_code_issue) et l'envoie par e-mail AU BÉNÉFICIAIRE
//     avec le nom de l'expert et de sa société. Le code n'est jamais renvoyé à l'expert.
// POST { "action": "verify", "mandate_id": "<uuid>", "code": "123456" }
//   → vérifie le code (presence_code_check) ; si bon, envoie au bénéficiaire « Identité confirmée ».
//
// Sécurité : JWT de l'expert obligatoire (verify_jwt = true) ; l'identité est lue dans le jeton, puis
// passée aux fonctions SQL réservées à la clé service. Toutes les règles (expert attribué, statut,
// 30 min, 5 essais, 3 envois, 1 envoi par minute) sont en base.
// Secrets : BREVO_API_KEY (Brevo → Paramètres → SMTP & API), facultatif BREVO_SENDER_EMAIL / BREVO_SENDER_NAME.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
// Qui envoie l'expert : l'organisation de gestion (VELAY BAT), pour le compte de l'assureur donneur d'ordre s'il est connu.
const mandBy = (r: { organization?: string; insurer?: string }) =>
  r.insurer ? `${r.organization} pour le compte de ${r.insurer}` : String(r.organization ?? "");
const maskEmail = (e: string) => { const [u, d] = String(e).split("@"); return `${(u ?? "").slice(0, 1)}•••@${d ?? ""}`; };

const frame = (title: string, body: string) => `<!doctype html><html lang="fr"><body style="margin:0;background:#f4f5f7;font-family:Arial,Helvetica,sans-serif;color:#1f2937">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" style="max-width:520px;background:#ffffff;border:1px solid #e5e7eb;border-radius:12px" cellpadding="0" cellspacing="0">
<tr><td style="padding:24px 24px 8px"><div style="font-size:13px;color:#1e3a8a;font-weight:bold;letter-spacing:.5px">PLOMI</div>
<h1 style="font-size:20px;margin:8px 0 0;color:#1e3a8a">${title}</h1></td></tr>
<tr><td style="padding:8px 24px 24px;font-size:15px;line-height:1.5">${body}</td></tr></table>
<p style="font-size:12px;color:#6b7280;max-width:520px">Message automatique envoyé par PLOMI pour le compte de votre assureur. Merci de ne pas y répondre.</p>
</td></tr></table></body></html>`;

async function sendMail(to: string, toName: string, subject: string, html: string, text: string, tag: string) {
  const key = Deno.env.get("BREVO_API_KEY");
  if (!key) throw new Error("Envoi d'e-mail non configuré (BREVO_API_KEY manquante)");
  const r = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": key, "Content-Type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: { email: Deno.env.get("BREVO_SENDER_EMAIL") ?? "noreply@plomi.fr", name: Deno.env.get("BREVO_SENDER_NAME") ?? "PLOMI" },
      to: [{ email: to, name: toName || undefined }],
      subject, htmlContent: html, textContent: text, tags: ["plomi", tag],
    }),
  });
  if (!r.ok) throw new Error(`Brevo a refusé l'envoi (${r.status}) : ${(await r.text()).slice(0, 200)}`);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée" }, 405);
  try {
    const { action, mandate_id, code } = await req.json().catch(() => ({}));
    if (!mandate_id || !["request", "verify"].includes(action)) return json({ ok: false, error: "Paramètres invalides" }, 400);

    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: u } = await asUser.auth.getUser();
    if (!u?.user?.id) return json({ ok: false, error: "Utilisateur non connecté" }, 401);

    if (action === "request") {
      // Vérifier la configuration AVANT de tirer un code (un envoi raté consommerait un des 3 envois)
      if (!Deno.env.get("BREVO_API_KEY")) return json({ ok: false, error: "Envoi d'e-mail non configuré : prévenez votre gestionnaire" }, 503);
      const { data: r, error } = await admin.rpc("presence_code_issue", { p_user_id: u.user.id, p_mandate_id: mandate_id });
      if (error) return json({ ok: false, error: error.message }, 500);
      if (!r?.ok) return json(r, 200);
      const who = `${esc(r.expert_name)}${r.company ? ` (${esc(r.company)})` : ""}`;
      // Type d'expertise, pour expliquer au bénéficiaire ce que la visite va comporter
      const { data: md } = await admin.from("mandates").select("mandate_type").eq("id", mandate_id).maybeSingle();
      const isRdfs = String(md?.mandate_type ?? "") === "rdfs";
      const nature = isRdfs
        ? "une recherche de fuite spécialisée (RDFS) : l'expert doit trouver l'origine du dommage, ce qui peut demander une ouverture très localisée (par exemple un petit perçage dans une cloison pour voir une canalisation)"
        : "une recherche de fuite (RDF) : des mesures d'humidité sans aucune dégradation, pour identifier la source dans la mesure du possible";
      const allowHtml = `<p style="margin:16px 0 4px;font-weight:bold;color:#1e3a8a">Pourquoi ce code ?</p>
           <p style="margin:0">Il garantit que la personne qui se présente chez vous est bien l'expert envoyé par votre assureur, et non quelqu'un qui se ferait passer pour lui. Seul l'expert mandaté peut le saisir, dans son application connectée à PLOMI.</p>
           <p style="margin:16px 0 4px;font-weight:bold;color:#1e3a8a">Ce que ce code autorise</p>
           <ul style="margin:0;padding-left:20px">
             <li>Confirmer l'identité de l'expert et enregistrer son arrivée chez vous.</li>
             <li>Lui permettre de commencer ${nature}.</li>
             <li>Rien d'autre : ce code ne donne accès ni à votre logement en votre absence, ni à vos données, ni à un paiement.${isRdfs ? " Toute ouverture ou dégradation, même minime, nécessite en plus votre accord écrit, que l'expert vous demandera sur place." : ""}</li>
           </ul>`;
      const allowText = `\n\nPourquoi ce code ? Il garantit que la personne qui se présente chez vous est bien l'expert envoyé par votre assureur. Seul l'expert mandaté peut le saisir dans son application.\nCe que ce code autorise : confirmer l'identité de l'expert, enregistrer son arrivée et lui permettre de commencer ${nature}. Rien d'autre : ni accès à votre logement en votre absence, ni à vos données, ni à un paiement.${isRdfs ? " Toute ouverture ou dégradation nécessite en plus votre accord écrit." : ""}`;
      try { await sendMail(r.email, r.beneficiary_first_name ?? "",
        `PLOMI — votre code de vérification : ${r.code}`,
        frame("Votre expert est arrivé",
          `<p>Bonjour ${esc(r.beneficiary_first_name ?? "")},</p>
           <p><strong>${who}</strong> se présente chez vous pour le dossier <strong>${esc(r.reference)}</strong>, missionné par <strong>${esc(mandBy(r))}</strong>.</p>
           <p>Pour confirmer son identité, communiquez-lui ce code. Il doit le saisir dans son application :</p>
           <p style="font-size:32px;letter-spacing:6px;font-weight:bold;color:#1e3a8a;text-align:center;margin:20px 0">${esc(r.code)}</p>
           <p>Ce code est valable 30 minutes. <strong>Ne le donnez qu'à la personne présente chez vous.</strong> Vous recevrez ensuite un e-mail confirmant son identité.</p>
           ${allowHtml}
           <p style="color:#b91c1c;margin-top:16px">Si personne ne se présente, ou si la personne n'est pas ${esc(r.expert_name)}, ne la laissez pas entrer et contactez votre assureur.</p>`),
        `Bonjour,\n${r.expert_name}${r.company ? ` (${r.company})` : ""} se présente chez vous pour le dossier ${r.reference}, missionné par ${mandBy(r)}.\nCode à lui communiquer : ${r.code} (valable 30 minutes). Ne le donnez qu'à la personne présente chez vous.${allowText}\n\nSi la personne n'est pas ${r.expert_name}, ne la laissez pas entrer et contactez votre assureur.`,
        "presence-code");
      } catch (e) {
        // Envoi refusé : on rend l'envoi consommé (le code n'est jamais parti) et on trace la cause
        console.error("presence-verification : envoi du code impossible", String((e as Error)?.message ?? e));
        await admin.from("presence_verifications").update({ send_count: Math.max(0, Number(r.send_count ?? 1) - 1) })
          .eq("mandate_id", mandate_id).is("verified_at", null);
        return json({ ok: false, error: "L'e-mail n'a pas pu être envoyé au bénéficiaire. Réessayez dans un instant ou prévenez votre gestionnaire." }, 200);
      }
      return json({ ok: true, sent_to: maskEmail(r.email), expires_at: r.expires_at, sends_left: 3 - Number(r.send_count ?? 0) });
    }

    // action === "verify"
    const { data: r, error } = await admin.rpc("presence_code_check", { p_user_id: u.user.id, p_mandate_id: mandate_id, p_code: String(code ?? "") });
    if (error) return json({ ok: false, error: error.message }, 500);
    if (!r?.ok || r.already) return json(r, 200);
    let mail_sent = true;
    try {
      const who = `${esc(r.expert_name)}${r.company ? ` (${esc(r.company)})` : ""}`;
      await sendMail(r.email, r.beneficiary_first_name ?? "",
        `PLOMI — identité de votre expert confirmée (${r.reference})`,
        frame("Identité confirmée",
          `<p>Bonjour ${esc(r.beneficiary_first_name ?? "")},</p>
           <p>La personne présente chez vous a saisi le bon code : il s'agit bien de <strong>${who}</strong>, expert missionné par <strong>${esc(mandBy(r))}</strong> pour le dossier <strong>${esc(r.reference)}</strong>.</p>
           <p>Vous pouvez le laisser procéder à l'expertise.</p>`),
        `Identité confirmée : la personne présente chez vous est bien ${r.expert_name}${r.company ? ` (${r.company})` : ""}, expert missionné par ${mandBy(r)} pour le dossier ${r.reference}.`,
        "presence-confirmed");
    } catch (_) {
      mail_sent = false; // la présence est vérifiée en base ; seul l'e-mail de confirmation a échoué
    }
    return json({ ok: true, verified: true, confirmation_sent: mail_sent });
  } catch (e) {
    console.error("presence-verification : erreur", String((e as Error)?.message ?? e));
    return json({ ok: false, error: String((e as Error)?.message ?? e) }, 500);
  }
});
