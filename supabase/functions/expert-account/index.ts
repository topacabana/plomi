// PLOMI — expert-account (CC B, app expert)
// POST { "action": "stats_pdf" }                    -> { pdf_url }  rapport de statistiques + axes d'amélioration
// POST { "action": "change_email", "email": "..." } -> { message }  mail de confirmation envoyé à la nouvelle adresse
// POST { "action": "delete" }                       -> { message }  expert_delete_profile + blocage du compte
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { PDFDocument, StandardFonts, rgb, PDFFont } from "npm:pdf-lib@1.17.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const BLUE = rgb(0.118, 0.227, 0.541), GREY = rgb(0.39, 0.45, 0.55), DARK = rgb(0.06, 0.09, 0.16);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const authHeader = req.headers.get("Authorization") ?? "";
    const asUser = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: u } = await asUser.auth.getUser();
    const userId = u?.user?.id;
    if (!userId) return json({ error: "Utilisateur non connecté" }, 401);

    if (body.action === "change_email") {
      const email = String(body.email ?? "").trim().toLowerCase();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: "Adresse e-mail invalide" }, 400);
      if (email === (u.user.email ?? "").toLowerCase()) return json({ message: "" });
      const res = await fetch(`${url}/auth/v1/user`, {
        method: "PUT",
        headers: { Authorization: authHeader, apikey: anon, "Content-Type": "application/json" },
        body: JSON.stringify({ email }),
      });
      const out = await res.json().catch(() => ({}));
      if (!res.ok) return json({ error: out.msg ?? out.error_description ?? "Changement d'e-mail impossible" }, 400);
      return json({ message: `Un lien de confirmation a été envoyé à ${email}. L'adresse changera après validation.` });
    }

    if (body.action === "delete") {
      const { error } = await asUser.rpc("expert_delete_profile");
      if (error) return json({ error: error.message }, 400);
      await admin.auth.admin.updateUserById(userId, { ban_duration: "876000h" });
      return json({ message: "Profil supprimé" });
    }

    if (body.action === "stats_pdf") {
      const { data: p, error } = await asUser.rpc("expert_profile_data");
      if (error || !p) return json({ error: error?.message ?? "Profil introuvable" }, 400);

      const pdf = await PDFDocument.create();
      const font = await pdf.embedFont(StandardFonts.Helvetica), bold = await pdf.embedFont(StandardFonts.HelveticaBold);
      const safe = (f: PDFFont, s: string) =>
        [...String(s ?? "")].map((c) => { try { f.encodeText(c); return c; } catch { return "?"; } }).join("");
      const W = 595.28, H = 841.89, M = 48;
      const page = pdf.addPage([W, H]);
      let y = H - M;
      page.drawRectangle({ x: 0, y: H - 70, width: W, height: 70, color: BLUE });
      page.drawText("PLOMI", { x: M, y: H - 42, size: 22, font: bold, color: rgb(1, 1, 1) });
      page.drawText(safe(font, "Rapport de statistiques expert"), { x: M, y: H - 60, size: 11, font, color: rgb(0.85, 0.89, 1) });
      y = H - 100;
      const line = (t: string, o: { size?: number; f?: PDFFont; color?: any } = {}) => {
        const size = o.size ?? 11, f = o.f ?? font;
        let cur = "";
        for (const w of safe(f, t).split(/\s+/)) {
          const n = cur ? cur + " " + w : w;
          if (f.widthOfTextAtSize(n, size) > W - 2 * M && cur) { page.drawText(cur, { x: M, y, size, font: f, color: o.color ?? DARK }); y -= size + 5; cur = w; } else cur = n;
        }
        if (cur) { page.drawText(cur, { x: M, y, size, font: f, color: o.color ?? DARK }); y -= size + 5; }
      };
      const name = [p.civility, p.first_name, p.last_name].filter(Boolean).join(" ");
      line(name, { size: 15, f: bold });
      line(p.company_name ?? "", { color: GREY });
      line(`Édité le ${new Date().toLocaleDateString("fr-FR", { timeZone: "Europe/Paris" })}`, { size: 9, color: GREY });
      y -= 10;
      line("Statistiques", { size: 13, f: bold, color: BLUE });
      const pct = (v: unknown) => (v === null || v === undefined ? "non collecté" : `${v} %`);
      const rows: [string, unknown, string][] = [
        ["Rapidité d'intervention", p.rapidite, "durée des investigations et de rédaction du rapport"],
        ["Réactivité", p.reactivite, "délai de positionnement sur les nouveaux mandats"],
        ["Respect des créneaux", p.respect_creneaux, "arrivée au plus tard 15 min après le créneau prévu"],
        ["Précision des rapports", p.precision, "médias par investigation, pièces investiguées, mots par conclusion"],
      ];
      for (const [k, v, d] of rows) {
        page.drawText(safe(bold, k), { x: M, y, size: 11, font: bold, color: DARK });
        page.drawText(safe(bold, pct(v)), { x: W - M - 90, y, size: 11, font: bold, color: BLUE });
        y -= 15;
        line(d, { size: 9, color: GREY });
        // barre
        if (typeof v === "number") {
          page.drawRectangle({ x: M, y: y + 2, width: W - 2 * M, height: 6, color: rgb(0.9, 0.92, 0.95) });
          page.drawRectangle({ x: M, y: y + 2, width: (W - 2 * M) * Math.max(0, Math.min(100, v)) / 100, height: 6, color: BLUE });
        }
        y -= 16;
      }
      y -= 6;
      line("Axes d'amélioration", { size: 13, f: bold, color: BLUE });
      const axes: string[] = p.axes ?? [];
      if (!axes.length) line("Aucun axe prioritaire : vos indicateurs collectés sont au-dessus de 50 %.", { color: GREY });
      axes.forEach((a) => line("• " + a));
      y -= 6;
      line("Les pourcentages de rapidité, réactivité et précision situent l'expert par rapport aux autres experts PLOMI (100 % = meilleur).", { size: 8, color: GREY });

      const bytes = await pdf.save();
      const path = `exports/${userId}/statistiques_${Date.now()}.pdf`;
      const { error: eUp } = await admin.storage.from("documents").upload(path, bytes, { contentType: "application/pdf", upsert: true });
      if (eUp) return json({ error: "Upload impossible : " + eUp.message }, 500);
      const { data: signed } = await admin.storage.from("documents").createSignedUrl(path, 7 * 24 * 3600, { download: "statistiques_plomi.pdf" });
      await asUser.rpc("log_expert_profile_event", { p_action: "stats_report_downloaded" });
      return json({ pdf_url: signed?.signedUrl });
    }

    return json({ error: "Action inconnue" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
