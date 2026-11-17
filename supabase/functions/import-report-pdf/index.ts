// PLOMI — import-report-pdf
// Rapport d'erreurs d'un import CSV (page Import_CSV), à transmettre à l'assurance.
// Remplace le PDF construit dans le navigateur (jsPDF chargé depuis un CDN) par le JavaScript WeWeb.
// Appel : POST { file_name, raw_count, missing_required[], rows[] }  (JWT obligatoire)
//   rows : lignes en erreur, en échec ou avec avertissements, telles que renvoyées par
//          csv_import_build / csv_import_commit ({ line, title, subtitle, status, errors, warnings, message, data }).
// Accès : gestionnaire. Réponse 200 { ok: true, pdf_url } (lien signé 7 jours) ou 200 { ok: false, error }.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const refuse = (error: string) => json({ ok: false, error });
const NAVY = rgb(0.118, 0.227, 0.541), RED = rgb(0.725, 0.11, 0.11), ORANGE = rgb(0.706, 0.325, 0.035), GREY = rgb(0.39, 0.45, 0.55),
  DARK = rgb(0.118, 0.161, 0.231), LINE = rgb(0.886, 0.91, 0.941), ZEBRA = rgb(0.973, 0.98, 0.988);
const STATUS: Record<string, string> = { error: "Non importée", failed: "Échec à l'import", imported: "Importée (avertissements)", ready: "Importable (avertissements)" };
const TYPES: Record<string, string> = { visio: "Visio", rdf: "RDF", rdfs: "RDFS" };
const MAX_ROWS = 5000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée" }, 405);
  try {
    const p = await req.json().catch(() => ({}));
    const problems = (Array.isArray(p.rows) ? p.rows : []).slice(0, MAX_ROWS) as any[];
    if (!problems.length) return refuse("Aucune ligne en erreur : pas de rapport à générer.");

    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: u } = await asUser.auth.getUser();
    const userId = u?.user?.id;
    if (!userId) return json({ ok: false, error: "Utilisateur non connecté" }, 401);
    const { data: isManager } = await asUser.rpc("is_manager");
    if (!isManager) return refuse("Réservé aux gestionnaires.");

    const fileName = String(p.file_name ?? "import");
    const rejected = problems.filter((r) => ["error", "failed"].includes(r.status));
    const warned = problems.length - rejected.length;
    const missing = (Array.isArray(p.missing_required) ? p.missing_required : []).map(String);

    // ---- PDF (paysage A4)
    const pdf = await PDFDocument.create();
    pdf.setTitle(`Rapport d'erreurs - ${fileName}`);
    pdf.setAuthor("PLOMI");
    const font = await pdf.embedFont(StandardFonts.Helvetica), bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const safe = (f: PDFFont, t: unknown) => [...String(t ?? "")].map((c) => { try { f.encodeText(c); return c; } catch { return "?"; } }).join("");
    const W = 841.89, H = 595.28, M = 40;
    const cols = [
      { head: "Ligne", w: 36 }, { head: "Bénéficiaire", w: 95 }, { head: "Adresse", w: 135 }, { head: "Type", w: 38 },
      { head: "Statut", w: 80 }, { head: "Erreurs (bloquantes)", w: 200, color: RED }, { head: "Valeurs ignorées", w: W - 2 * M - 584, color: ORANGE },
    ];
    const wrap = (t: string, f: PDFFont, size: number, maxW: number) => {
      const out: string[] = [];
      for (const para of String(t ?? "").split(/\r?\n/)) {
        let line = "";
        for (const w of safe(f, para).split(/\s+/)) { const x = line ? line + " " + w : w; if (f.widthOfTextAtSize(x, size) > maxW && line) { out.push(line); line = w; } else line = x; }
        out.push(line);
      }
      return out;
    };
    const stamp = new Date().toLocaleString("fr-FR", { timeZone: "Europe/Paris", dateStyle: "short", timeStyle: "short" });

    let page!: PDFPage, y = 0;
    const header = (first: boolean) => {
      page = pdf.addPage([W, H]);
      y = H - 44;
      if (first) {
        page.drawText(safe(bold, "Rapport d'erreurs d'import"), { x: M, y, size: 18, font: bold, color: NAVY }); y -= 18;
        page.drawText(safe(font, `Fichier : ${fileName}   ·   Généré le ${stamp}`), { x: M, y, size: 10, font, color: GREY }); y -= 22;
        page.drawText(safe(font, `${p.raw_count ?? "?"} ligne(s) dans le fichier`), { x: M, y, size: 11, font, color: NAVY });
        page.drawText(safe(font, `${rejected.length} ligne(s) non importée(s), à corriger et renvoyer`), { x: M + 190, y, size: 11, font, color: RED });
        page.drawText(safe(font, `${warned} ligne(s) avec des valeurs ignorées`), { x: M + 500, y, size: 11, font, color: ORANGE });
        y -= 16;
        if (missing.length) {
          page.drawText(safe(font, `Colonnes obligatoires absentes du fichier : ${missing.join(", ")}`), { x: M, y, size: 10, font, color: RED }); y -= 16;
        }
      }
      page.drawRectangle({ x: M, y: y - 16, width: W - 2 * M, height: 18, color: NAVY });
      let x = M;
      for (const c of cols) { page.drawText(safe(bold, c.head), { x: x + 4, y: y - 11, size: 8.5, font: bold, color: rgb(1, 1, 1) }); x += c.w; }
      y -= 18;
    };
    header(true);

    problems.forEach((row, idx) => {
      const d = row.data || {};
      const errors = [...(row.errors || [])].map(String);
      if (row.status === "failed" && row.message) errors.push(String(row.message).replace(/^Échec : /, ""));
      const vals = [
        String(row.line ?? ""), row.title ?? "", row.subtitle || "-", TYPES[d.mandate_type] || "-", STATUS[row.status] || row.status || "",
        errors.map((e) => "• " + e).join("\n") || "-", (row.warnings || []).map((w: unknown) => "• " + w).join("\n") || "-",
      ];
      const cells = vals.map((v, i) => wrap(v, font, 8, cols[i].w - 8));
      const h = Math.max(...cells.map((l) => l.length)) * 10 + 6;
      if (y - h < M + 16) header(false);
      if (idx % 2) page.drawRectangle({ x: M, y: y - h, width: W - 2 * M, height: h, color: ZEBRA });
      let x = M;
      cells.forEach((lines, i) => { lines.forEach((l, k) => page.drawText(l, { x: x + 4, y: y - 10 - k * 10, size: 8, font, color: cols[i].color ?? DARK })); x += cols[i].w; });
      y -= h;
      page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.4, color: LINE });
    });

    const note = "Les numéros de ligne correspondent au fichier d'origine (la ligne 1 est l'en-tête). Les lignes « Non importée » doivent être corrigées puis renvoyées ; les valeurs ignorées n'ont pas été reprises dans le mandat.";
    const noteLines = wrap(note, font, 9, W - 2 * M);
    if (y - noteLines.length * 12 - 10 < M + 16) header(false);
    y -= 14;
    noteLines.forEach((l) => { page.drawText(l, { x: M, y, size: 9, font, color: GREY }); y -= 12; });

    const pages = pdf.getPages();
    pages.forEach((pg, i) => {
      pg.drawText(safe(font, `PLOMI · ${fileName}`), { x: M, y: 18, size: 8, font, color: GREY });
      pg.drawText(`Page ${i + 1}/${pages.length}`, { x: W - M - 50, y: 18, size: 8, font, color: GREY });
    });
    const bytes = await pdf.save();

    const base = fileName.replace(/\.[^.]+$/, "").normalize("NFD").replace(/[^\w-]+/g, "_").slice(0, 60) || "import";
    const path = `exports/${userId}/rapport_erreurs_${base}_${Date.now()}.pdf`;
    const { error: eUp } = await admin.storage.from("documents").upload(path, bytes, { contentType: "application/pdf", upsert: true });
    if (eUp) return refuse("Enregistrement du PDF impossible : " + eUp.message);
    const { data: sg } = await admin.storage.from("documents").createSignedUrl(path, 7 * 24 * 3600);
    return json({ ok: true, pdf_url: sg?.signedUrl, count: problems.length });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message ?? e) }, 500);
  }
});
