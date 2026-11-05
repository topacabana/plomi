// PLOMI — kpi-report-pdf (CC mandataire L)
// Fabrique le rapport KPI en PDF à partir de kpi_report (calcul et droits en base, avec le compte de l'appelant),
// le range dans documents/exports/<user>/ et renvoie un lien signé valable 7 jours (à télécharger ou partager).
// Appel : POST { start, end, scope: 'experts'|'mandataire', expert_ids: [], kpis: [], mode: 'brut'|'commente' }
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const BLUE = rgb(0.118, 0.227, 0.541), GREY = rgb(0.39, 0.45, 0.55), DARK = rgb(0.06, 0.09, 0.16);
const SEVEN_DAYS = 7 * 24 * 3600;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) return json({ error: "Non connecté" }, 401);

    const b = await req.json().catch(() => ({}));
    const { data: rep, error: eR } = await asUser.rpc("kpi_report", {
      p_start: b.start ?? null, p_end: b.end ?? null, p_scope: b.scope ?? "experts",
      p_expert_ids: b.expert_ids ?? [], p_kpis: b.kpis ?? [],
    });
    if (eR) return json({ error: eR.message }, 400);
    const { data: catalog } = await asUser.rpc("kpi_catalog");
    const cat: Record<string, any> = {};
    for (const c of catalog ?? []) cat[c.code] = c;
    const codes: string[] = (b.kpis?.length ? b.kpis : Object.keys(cat));
    const commented = b.mode === "commente";

    const pdf = await PDFDocument.create();
    pdf.setTitle("Rapport KPI PLOMI");
    const font = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const safe = (f: PDFFont, s: string) =>
      [...String(s ?? "")].map((c) => { try { f.encodeText(c); return c; } catch { return "?"; } }).join("");
    const W = 595.28, H = 841.89, M = 44;
    let page: PDFPage = pdf.addPage([W, H]); let y = H - M;
    const need = (h: number) => { if (y - h < M + 20) { page = pdf.addPage([W, H]); y = H - M; } };
    const line = (s: string, o: { size?: number; f?: PDFFont; color?: any; x?: number } = {}) => {
      const size = o.size ?? 10, f = o.f ?? font, x = o.x ?? M, maxW = W - M - x;
      let cur = "";
      const out: string[] = [];
      for (const w of safe(f, s).split(/\s+/)) {
        const t = cur ? cur + " " + w : w;
        if (f.widthOfTextAtSize(t, size) > maxW && cur) { out.push(cur); cur = w; } else cur = t;
      }
      out.push(cur);
      for (const l of out) { need(size + 4); page.drawText(l, { x, y: y - size, size, font: f, color: o.color ?? DARK }); y -= size + 4; }
    };

    page.drawRectangle({ x: 0, y: H - 64, width: W, height: 64, color: BLUE });
    page.drawText("PLOMI", { x: M, y: H - 38, size: 20, font: bold, color: rgb(1, 1, 1) });
    page.drawText(safe(font, `Rapport KPI — ${rep.scope === "mandataire" ? "Mandataire" : "Experts"} — du ${rep.start} au ${rep.end}`),
      { x: M, y: H - 54, size: 10, font, color: rgb(0.85, 0.89, 1) });
    y = H - 84;
    line(`Généré le ${new Date().toLocaleString("fr-FR", { timeZone: "Europe/Paris" })} par ${user.email}`, { size: 9, color: GREY });
    line(commented ? "Rapport de présentation : chaque indicateur est accompagné de son thème et de son unité." : "Relevé brut des indicateurs.", { size: 9, color: GREY });
    y -= 6;

    for (const r of rep.rows ?? []) {
      need(40); y -= 6;
      line(r.label ?? "", { size: 13, f: bold, color: BLUE });
      for (const code of codes) {
        const c = cat[code]; if (!c) continue;
        const v = r.values?.[code];
        const val = !c.available ? "donnée non collectée" : (v === null || v === undefined ? "–" : `${v}${c.unit && c.unit !== "texte" && c.unit !== "nb" ? " " + c.unit : ""}`);
        if (commented) line(`${c.label} (${c.theme}) : ${val}`, { size: 10 });
        else line(`${c.label} : ${val}`, { size: 10 });
      }
    }
    if (!(rep.rows ?? []).length) line("Aucun expert sélectionné.", { color: GREY });
    const pages = pdf.getPages();
    pages.forEach((pg, i) => pg.drawText(`PLOMI — rapport KPI — page ${i + 1}/${pages.length}`, { x: M, y: 22, size: 8, font, color: GREY }));
    const bytes = await pdf.save();

    const path = `exports/${user.id}/kpi_${Date.now()}.pdf`;
    const { error: eU } = await admin.storage.from("documents").upload(path, bytes, { contentType: "application/pdf", upsert: true });
    if (eU) return json({ error: "Upload impossible : " + eU.message }, 500);
    const { data: signed } = await admin.storage.from("documents").createSignedUrl(path, SEVEN_DAYS);
    await admin.from("activity_logs").insert({
      user_id: user.id, entity_type: "broadcast", entity_id: crypto.randomUUID(), action: "kpi_report_exported",
      new_values_json: { scope: rep.scope, start: rep.start, end: rep.end, kpis: codes.length, rows: (rep.rows ?? []).length, mode: b.mode ?? "brut", purpose: b.purpose ?? "download" },
    });
    return json({ pdf_url: signed?.signedUrl, path });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
