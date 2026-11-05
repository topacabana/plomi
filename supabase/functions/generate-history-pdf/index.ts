// PLOMI — generate-history-pdf
// PDF de l'historique d'un mandat (vue mandate_history), avec les mêmes filtres
// et le même masque de colonnes que la popup Historique.
// Appel : POST { mandate_id, search?, operator?, status?, start?, end?, columns? }
//   columns : sous-ensemble de ["date","action","statut","motif","operateur"]
// Accès : gestionnaire, mandats de son organisation. Renvoie un lien signé (7 jours).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const BLUE = rgb(0.118, 0.227, 0.541), GREY = rgb(0.39, 0.45, 0.55), DARK = rgb(0.06, 0.09, 0.16), LINE = rgb(0.88, 0.9, 0.93);
const fmt = (d?: string | null) => d ? new Date(d).toLocaleString("fr-FR", { timeZone: "Europe/Paris", dateStyle: "short", timeStyle: "short" }) : "–";
const ALL = ["date", "action", "statut", "motif", "operateur"];
const HEAD: Record<string, string> = { date: "Date / heure", action: "Action", statut: "Statut", motif: "Motif", operateur: "Opérateur" };
const WIDTH: Record<string, number> = { date: 80, action: 110, statut: 120, motif: 140, operateur: 95 };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);
  try {
    const p = await req.json().catch(() => ({}));
    if (!p.mandate_id) return json({ error: "mandate_id manquant" }, 400);
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: u } = await asUser.auth.getUser();
    const userId = u?.user?.id;
    if (!userId) return json({ error: "Utilisateur non connecté" }, 401);
    const { data: prof } = await admin.from("user_profiles").select("role,organization_id").eq("id", userId).maybeSingle();
    if (prof?.role !== "gestionnaire_assurance") return json({ error: "Réservé aux gestionnaires" }, 403);

    const { data: m } = await admin.from("mandates").select("id,reference,address_line_1,postal_code,city").eq("id", p.mandate_id).eq("insurance_org_id", prof.organization_id).maybeSingle();
    if (!m) return json({ error: "Mandat introuvable" }, 404);

    let q = admin.from("mandate_history").select("*").eq("mandate_id", p.mandate_id).order("created_at", { ascending: false });
    if (p.operator) q = q.eq("operator_name", p.operator);
    if (p.status) q = q.eq("status_to", p.status);
    if (p.start) q = q.gte("created_at", p.start);
    if (p.end) q = q.lt("created_at", new Date(new Date(p.end).getTime() + 86400000).toISOString().slice(0, 10));
    const { data: rows0, error } = await q;
    if (error) return json({ error: error.message }, 500);
    const s = String(p.search ?? "").trim().toLowerCase();
    const rows = (rows0 ?? []).filter((r: any) => !s ||
      [r.action_label, r.motif, r.operator_name, r.status_from_label, r.status_to_label].some((v) => String(v ?? "").toLowerCase().includes(s)));
    const cols = (Array.isArray(p.columns) && p.columns.length ? p.columns : ALL).filter((c: string) => ALL.includes(c));

    // ---- PDF (paysage A4)
    const pdf = await PDFDocument.create();
    pdf.setTitle(`Historique ${m.reference}`);
    pdf.setAuthor("PLOMI");
    const font = await pdf.embedFont(StandardFonts.Helvetica), bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const safe = (f: PDFFont, t: string) => [...String(t ?? "")].map((c) => { try { f.encodeText(c); return c; } catch { return "?"; } }).join("");
    const W = 841.89, H = 595.28, M = 40;
    const totalW = cols.reduce((a: number, c: string) => a + WIDTH[c], 0);
    const scale = (W - 2 * M) / totalW;
    const cw = (c: string) => WIDTH[c] * scale;
    const wrap = (t: string, f: PDFFont, size: number, maxW: number) => {
      const out: string[] = [];
      for (const para of String(t ?? "").split(/\r?\n/)) {
        let line = "";
        for (const w of safe(f, para).split(/\s+/)) { const x = line ? line + " " + w : w; if (f.widthOfTextAtSize(x, size) > maxW && line) { out.push(line); line = w; } else line = x; }
        out.push(line);
      }
      return out;
    };

    let page!: PDFPage, y = 0;
    const header = (first: boolean) => {
      page = pdf.addPage([W, H]);
      page.drawRectangle({ x: 0, y: H - 56, width: W, height: 56, color: BLUE });
      page.drawText("PLOMI", { x: M, y: H - 34, size: 18, font: bold, color: rgb(1, 1, 1) });
      page.drawText(safe(font, `Historique du mandat ${m.reference}`), { x: M + 80, y: H - 33, size: 13, font, color: rgb(1, 1, 1) });
      y = H - 74;
      if (first) {
        const filt = [p.search && `recherche « ${p.search} »`, p.operator && `opérateur : ${p.operator}`, p.status && `statut : ${p.status}`,
          (p.start || p.end) && `période : ${p.start ?? "…"} au ${p.end ?? "…"}`].filter(Boolean).join(" · ");
        page.drawText(safe(font, [m.address_line_1, [m.postal_code, m.city].filter(Boolean).join(" ")].filter(Boolean).join(", ")), { x: M, y, size: 9.5, font, color: GREY });
        y -= 14;
        page.drawText(safe(font, `${rows.length} événement(s)${filt ? " — filtres : " + filt : ""}`), { x: M, y, size: 9.5, font, color: GREY });
        y -= 18;
      }
      let x = M;
      page.drawRectangle({ x: M, y: y - 16, width: W - 2 * M, height: 18, color: rgb(0.93, 0.95, 0.98) });
      for (const c of cols) { page.drawText(safe(bold, HEAD[c]), { x: x + 4, y: y - 11, size: 9, font: bold, color: BLUE }); x += cw(c); }
      y -= 20;
    };
    header(true);
    if (!rows.length) page.drawText(safe(font, "Aucun événement pour ces critères."), { x: M, y: y - 12, size: 10, font, color: GREY });

    for (const r of rows as any[]) {
      const val: Record<string, string> = {
        date: fmt(r.created_at),
        action: r.action_label ?? "",
        statut: r.status_to_label ? `${r.status_from_label ?? "–"} » ${r.status_to_label}` : "–",
        motif: r.motif ?? "–",
        operateur: `${r.operator_name ?? "–"}${r.operator_role && r.operator_role !== "Système" ? " (" + r.operator_role + ")" : ""}`,
      };
      const cells = cols.map((c: string) => wrap(val[c], font, 8.5, cw(c) - 8));
      const h = Math.max(...cells.map((l: string[]) => l.length)) * 11 + 6;
      if (y - h < M + 16) header(false);
      let x = M;
      cols.forEach((c: string, i: number) => { cells[i].forEach((l: string, k: number) => page.drawText(l, { x: x + 4, y: y - 10 - k * 11, size: 8.5, font, color: DARK })); x += cw(c); });
      y -= h;
      page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.5, color: LINE });
      y -= 2;
    }
    const pages = pdf.getPages(), stamp = fmt(new Date().toISOString());
    pages.forEach((pg, i) => pg.drawText(safe(font, `PLOMI — ${m.reference} — historique généré le ${stamp} — page ${i + 1}/${pages.length}`), { x: M, y: 18, size: 8, font, color: GREY }));
    const bytes = await pdf.save();

    const path = `exports/${userId}/historique_${m.reference}_${Date.now()}.pdf`;
    const { error: eUp } = await admin.storage.from("documents").upload(path, bytes, { contentType: "application/pdf", upsert: true });
    if (eUp) return json({ error: "Upload impossible : " + eUp.message }, 500);
    // Bucket privé : lien signé valable 7 jours (utilisé aussi dans le mail)
    const { data: sg } = await admin.storage.from("documents").createSignedUrl(path, 7 * 24 * 3600);
    return json({ pdf_url: sg?.signedUrl ?? `${url}/storage/v1/object/public/documents/${path}`, count: rows.length, reference: m.reference });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
