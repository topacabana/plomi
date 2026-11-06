// PLOMI — expert-fiche-pdf (CC mandataire I/J)
// Fiches de recrutement experts en PDF, données lues avec le compte de l'appelant (recruitment_data : réservé aux gestionnaires).
// Appel : POST { expert_ids: [] (vide = toute la liste), purpose: 'download'|'share' }
// Réponse : { pdf_url } lien signé 7 jours.
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
const v = (x: unknown, unit = "") => (x === null || x === undefined || x === "" ? "–" : `${x}${unit}`);

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
    const { data, error } = await asUser.rpc("recruitment_data");
    if (error) return json({ error: error.message }, 400);
    const ids: string[] = Array.isArray(b.expert_ids) ? b.expert_ids : [];
    const experts = (data.experts ?? []).filter((e: any) => !ids.length || ids.includes(e.id));
    if (!experts.length) return json({ error: "Aucun expert à exporter" }, 400);

    const pdf = await PDFDocument.create();
    pdf.setTitle("Fiches de recrutement PLOMI");
    const font = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const safe = (f: PDFFont, s: string) =>
      [...String(s ?? "")].map((c) => { try { f.encodeText(c); return c; } catch { return "?"; } }).join("");
    const W = 595.28, H = 841.89, M = 44;
    let page: PDFPage = pdf.addPage([W, H]); let y = H - M;
    const need = (h: number) => { if (y - h < M + 20) { page = pdf.addPage([W, H]); y = H - M; } };
    const line = (s: string, o: { size?: number; f?: PDFFont; color?: any; x?: number } = {}) => {
      const size = o.size ?? 10, f = o.f ?? font, x = o.x ?? M, maxW = W - M - x;
      let cur = ""; const out: string[] = [];
      for (const w of safe(f, s).split(/\s+/)) {
        const t = cur ? cur + " " + w : w;
        if (f.widthOfTextAtSize(t, size) > maxW && cur) { out.push(cur); cur = w; } else cur = t;
      }
      out.push(cur);
      for (const l of out) { need(size + 4); page.drawText(l, { x, y: y - size, size, font: f, color: o.color ?? DARK }); y -= size + 4; }
    };

    page.drawRectangle({ x: 0, y: H - 64, width: W, height: 64, color: BLUE });
    page.drawText("PLOMI", { x: M, y: H - 38, size: 20, font: bold, color: rgb(1, 1, 1) });
    page.drawText(safe(font, `Fiches de recrutement — ${experts.length} expert(s)`), { x: M, y: H - 54, size: 10, font, color: rgb(0.85, 0.89, 1) });
    y = H - 84;
    line(`Généré le ${new Date().toLocaleString("fr-FR", { timeZone: "Europe/Paris" })} par ${user.email}`, { size: 9, color: GREY });
    line(`Données non collectées dans PLOMI : ${(data.non_collecte ?? []).join(", ")}.`, { size: 9, color: GREY });

    for (const e of experts) {
      need(150); y -= 10;
      page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.5, color: GREY }); y -= 6;
      line(`${e.company_name ?? ""} — ${e.first_name ?? ""} ${e.last_name ?? ""}`, { size: 13, f: bold, color: BLUE });
      line(`SIRET : ${v(e.siret)} · Adresse : ${v(e.address)}`, { size: 9 });
      line(`E-mail : ${v(e.email)} · Téléphone : ${v(e.phone)}`, { size: 9 });
      line(`Zones : ${v(e.coverage_zone)} · Agréments : ${(e.agreements ?? []).length ? e.agreements.join(", ").toUpperCase() : "–"}`, { size: 9 });
      line(`Rapports traités : Visio ${v(e.nb_visio)} · RDF ${v(e.nb_rdf)} · RDFS ${v(e.nb_rdfs)} · RDF/mois ${v(e.rdf_mois)} · RDFS/mois ${v(e.rdfs_mois)}`, { size: 9 });
      line(`Durée moyenne : RDF ${v(e.duree_rdf, " min")} · RDFS ${v(e.duree_rdfs, " min")} · Note client ${v(e.rating, "/5")}`, { size: 9 });
      line(`Scores PLO (sur 100) : précision ${v(e.precision)} · réactivité ${v(e.reactivite)} · rapidité ${v(e.rapidite)} · avis client ${v(e.avis_client)}`, { size: 9 });
    }
    const pages = pdf.getPages();
    pages.forEach((pg, i) => pg.drawText(`PLOMI — fiches de recrutement — page ${i + 1}/${pages.length}`, { x: M, y: 22, size: 8, font, color: GREY }));
    const bytes = await pdf.save();

    const path = `exports/${user.id}/fiches_experts_${Date.now()}.pdf`;
    const { error: eU } = await admin.storage.from("documents").upload(path, bytes, { contentType: "application/pdf", upsert: true });
    if (eU) return json({ error: "Upload impossible : " + eU.message }, 500);
    const { data: signed } = await admin.storage.from("documents").createSignedUrl(path, SEVEN_DAYS);
    await admin.from("activity_logs").insert({
      user_id: user.id, entity_type: "broadcast", entity_id: crypto.randomUUID(), action: "expert_fiches_exported",
      new_values_json: { experts: experts.length, all: !ids.length, purpose: b.purpose ?? "download" },
    });
    return json({ pdf_url: signed?.signedUrl, path, count: experts.length });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
