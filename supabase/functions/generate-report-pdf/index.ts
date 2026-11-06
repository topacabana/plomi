// PLOMI — generate-report-pdf (F54)
// Fabrique le PDF du rapport RDF d'un mandat, le range dans le stockage
// (documents/rapports/<mandat>/rapport_<rapport>.pdf), remplit rdf_reports.pdf_url
// et trace le fichier dans la table documents.
// Appel : POST { "report_id": "<uuid>" }   (JWT de l'utilisateur obligatoire)
// Autorisé : l'expert auteur du rapport, ou un gestionnaire_assurance.
// v3 : section Synthèse (hypothèses, préconisations et réserves, conclusion).
// v4 : section Annexes (médias de l'éditeur : titre, commentaire, cible de précision).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const STEPS: Record<number, string> = {
  1: "1. Inspection visuelle",
  2: "2. Colorant et fluorine",
  3: "3. Gaz traceur",
  4: "4. Relevé de sonde",
};
const TYPES: Record<string, string> = { visio: "Visio-expertise", rdf: "RDF", rdfs: "RDFS" };
const BLUE = rgb(0.118, 0.227, 0.541); // #1e3a8a
const GREY = rgb(0.39, 0.45, 0.55);
const DARK = rgb(0.06, 0.09, 0.16);
const RED = rgb(0.86, 0.15, 0.15);

// Bucket "documents" privé : chemin interne d'un lien public historique, et lien signé temporaire
const storagePath = (u: string) => {
  const m = String(u ?? "").split("?")[0].match(/\/storage\/v1\/object\/(?:public|sign|authenticated)\/documents\/(.+)$/);
  return m ? decodeURIComponent(m[1]) : null;
};
const SEVEN_DAYS = 7 * 24 * 3600;

const fmtDate = (d?: string | null) => {
  if (!d) return "–";
  const x = new Date(d);
  return x.toLocaleString("fr-FR", { timeZone: "Europe/Paris", dateStyle: "short", timeStyle: "short" });
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);

  try {
    const { report_id } = await req.json().catch(() => ({}));
    if (!report_id) return json({ error: "report_id manquant" }, 400);

    const url = Deno.env.get("SUPABASE_URL")!;
    const authHeader = req.headers.get("Authorization") ?? "";
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: u } = await asUser.auth.getUser();
    const userId = u?.user?.id;
    if (!userId) return json({ error: "Utilisateur non connecté" }, 401);

    // ---- Données
    const { data: report, error: eR } = await admin.from("rdf_reports").select("*").eq("id", report_id).single();
    if (eR || !report) return json({ error: "Rapport introuvable" }, 404);

    const { data: profile } = await admin.from("user_profiles").select("role,organization_id").eq("id", userId).maybeSingle();
    const { data: mOrg } = await admin.from("mandates").select("insurance_org_id").eq("id", report.mandate_id).maybeSingle();
    const allowed = report.created_by === userId ||
      (profile?.role === "gestionnaire_assurance" && !!profile?.organization_id && profile.organization_id === mOrg?.insurance_org_id);
    if (!allowed) return json({ error: "Accès refusé" }, 403);

    const { data: m } = await admin.from("mandates").select("*").eq("id", report.mandate_id).single();
    const [{ data: ben }, { data: exp }, { data: org }, { data: rooms }, { data: medias }] = await Promise.all([
      m?.beneficiary_id
        ? admin.from("beneficiaries").select("first_name,last_name,mobile_phone,email").eq("id", m.beneficiary_id).maybeSingle()
        : Promise.resolve({ data: null }),
      m?.assigned_expert_id
        ? admin.from("experts_with_profiles").select("first_name,last_name,company_name,phone,email").eq("id", m.assigned_expert_id).maybeSingle()
        : Promise.resolve({ data: null }),
      m?.insurance_org_id
        ? admin.from("organizations").select("name,logo_url").eq("id", m.insurance_org_id).maybeSingle()
        : Promise.resolve({ data: null }),
      admin.from("rdf_report_rooms").select("*").eq("report_id", report_id).order("step").order("position"),
      admin.from("report_media").select("*").eq("mandate_id", report.mandate_id).order("created_at"),
    ]);

    // ---- PDF
    const pdf = await PDFDocument.create();
    pdf.setTitle(`Rapport ${m?.reference ?? ""}`);
    pdf.setAuthor("PLOMI");
    pdf.setCreationDate(new Date());
    const font = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);

    // Caractères non supportés par la police standard -> remplacés
    const safe = (f: PDFFont, s: string) =>
      [...String(s ?? "")].map((c) => { try { f.encodeText(c); return c; } catch { return c === "\n" ? " " : "?"; } }).join("");

    const W = 595.28, H = 841.89, M = 48;
    let page: PDFPage = pdf.addPage([W, H]);
    let y = H - M;
    const newPage = () => { page = pdf.addPage([W, H]); y = H - M; };
    const need = (h: number) => { if (y - h < M + 20) newPage(); };

    const wrap = (text: string, f: PDFFont, size: number, maxW: number) => {
      const out: string[] = [];
      for (const para of safe(f, text).split(/\r?\n/)) {
        let line = "";
        for (const w of para.split(/\s+/)) {
          const t = line ? line + " " + w : w;
          if (f.widthOfTextAtSize(t, size) > maxW && line) { out.push(line); line = w; } else line = t;
        }
        out.push(line);
      }
      return out;
    };
    const text = (s: string, o: { size?: number; f?: PDFFont; color?: any; x?: number; maxW?: number; gap?: number } = {}) => {
      const size = o.size ?? 10, f = o.f ?? font, x = o.x ?? M, maxW = o.maxW ?? W - 2 * M;
      for (const l of wrap(s, f, size, maxW)) {
        need(size + 4);
        page.drawText(l, { x, y: y - size, size, font: f, color: o.color ?? DARK });
        y -= size + (o.gap ?? 4);
      }
    };
    const rule = () => { need(10); page.drawLine({ start: { x: M, y: y - 4 }, end: { x: W - M, y: y - 4 }, thickness: 0.5, color: rgb(0.85, 0.87, 0.9) }); y -= 12; };
    const kv = (k: string, v: string) => {
      need(14);
      page.drawText(safe(bold, k), { x: M, y: y - 10, size: 9.5, font: bold, color: GREY });
      const lines = wrap(v || "–", font, 9.5, W - 2 * M - 130);
      lines.forEach((l, i) => { if (i) { need(13); } page.drawText(l, { x: M + 130, y: y - 10, size: 9.5, font, color: DARK }); y -= 13; });
      y -= 1;
    };
    const loadImage = async (p: string) => {
      const sp = storagePath(p);
      let bytes: Uint8Array;
      if (sp) {
        const { data: blob, error: eD } = await admin.storage.from("documents").download(sp);
        if (eD || !blob) throw new Error();
        bytes = new Uint8Array(await blob.arrayBuffer());
      } else {
        const res = await fetch(p);
        if (!res.ok) throw new Error();
        bytes = new Uint8Array(await res.arrayBuffer());
      }
      const isPng = bytes[0] === 0x89 && bytes[1] === 0x50;
      const isJpg = bytes[0] === 0xff && bytes[1] === 0xd8;
      if (!isPng && !isJpg) throw new Error();
      return isPng ? await pdf.embedPng(bytes) : await pdf.embedJpg(bytes);
    };

    // En-tête
    page.drawRectangle({ x: 0, y: H - 70, width: W, height: 70, color: BLUE });
    page.drawText("PLOMI", { x: M, y: H - 42, size: 22, font: bold, color: rgb(1, 1, 1) });
    page.drawText(safe(font, "Rapport d'intervention"), { x: M, y: H - 60, size: 11, font, color: rgb(0.85, 0.89, 1) });
    const ref = safe(bold, m?.reference ?? "");
    page.drawText(ref, { x: W - M - bold.widthOfTextAtSize(ref, 14), y: H - 42, size: 14, font: bold, color: rgb(1, 1, 1) });
    y = H - 92;

    text("Mandat", { size: 13, f: bold, color: BLUE, gap: 6 });
    kv("Référence", m?.reference ?? "–");
    kv("Type", TYPES[m?.mandate_type] ?? m?.mandate_type ?? "–");
    kv("Sinistre", Array.isArray(m?.sinister_type) ? m.sinister_type.join(", ") : (m?.sinister_type ?? "–"));
    kv("Adresse", [m?.address_line_1, m?.address_line_2, [m?.postal_code, m?.city].filter(Boolean).join(" ")].filter(Boolean).join(", "));
    kv("Mandataire", org?.name ?? "–");
    kv("Bénéficiaire", ben ? `${ben.first_name ?? ""} ${ben.last_name ?? ""}`.trim() : "–");
    kv("Expert", exp ? `${exp.first_name ?? ""} ${exp.last_name ?? ""}`.trim() + (exp.company_name ? ` — ${exp.company_name}` : "") : "–");
    kv("Intervention", `Démarrée le ${fmtDate(m?.started_at)} · rapport envoyé le ${fmtDate(report.submitted_at)}`);
    kv("Statut du rapport", report.status === "validated" ? "Validé" : "Envoyé, en attente de validation");
    rule();

    // Pièces par étape
    text("Constats par pièce", { size: 13, f: bold, color: BLUE, gap: 6 });
    if (!rooms?.length) text("Aucune pièce renseignée.", { color: GREY });

    for (const r of rooms ?? []) {
      need(60);
      y -= 4;
      text(`${STEPS[r.step] ?? "Étape " + r.step} — ${[r.room, r.wall, r.matiere].filter(Boolean).join(" · ")}`, { size: 11, f: bold });
      const c: string[] = [];
      if (r.step <= 2 && r.infiltration !== null) c.push(r.infiltration ? "Infiltration constatée" : "Infiltration non constatée");
      if (r.moisissure) c.push("Présence de moisissure");
      if (r.peinture_endommagee) c.push("Peinture ou revêtement endommagé");
      if (r.step === 3 && r.gaz_detecte !== null) c.push(r.gaz_detecte ? "Gaz détecté" : "Gaz non détecté");
      if (r.sonde_type) c.push(`Sonde ${r.sonde_type === "picot" ? "à picot" : "à boule"} : ${r.sonde_percent ?? "–"} %`);
      text(c.length ? c.join(" · ") : "Aucun constat coché", { size: 10 });
      if (r.commentaire) text(r.commentaire, { size: 10, color: GREY });

      // Photos : 3 par ligne
      const photos: string[] = r.photos ?? [];
      const pw = (W - 2 * M - 2 * 10) / 3, ph = pw * 0.75;
      let col = 0;
      for (const p of photos) {
        try {
          const img = await loadImage(p);
          if (col === 0) need(ph + 8);
          const s = Math.min(pw / img.width, ph / img.height);
          page.drawImage(img, { x: M + col * (pw + 10), y: y - ph, width: img.width * s, height: img.height * s });
          col = (col + 1) % 3;
          if (col === 0) y -= ph + 8;
        } catch {
          if (col !== 0) { y -= ph + 8; col = 0; }
          text("Photo non intégrable (format non pris en charge) : " + p, { size: 8, color: GREY });
        }
      }
      if (col !== 0) y -= ph + 8;
      rule();
    }

    // Synthèse
    text("Synthèse", { size: 13, f: bold, color: BLUE, gap: 6 });
    const hyp: string[] = report.hypotheses ?? [];
    text("Hypothèses", { size: 11, f: bold });
    if (!hyp.length) text("Aucune hypothèse.", { size: 10, color: GREY });
    hyp.forEach((h, i) => text(`${i + 1}. ${h}`, { size: 10 }));
    y -= 4;
    text("Préconisations et réserves", { size: 11, f: bold });
    text(report.preconisations_reserves || "Aucune.", { size: 10, color: report.preconisations_reserves ? DARK : GREY });
    y -= 4;
    text("Conclusion", { size: 11, f: bold });
    text(report.rapport_conclusions || "Pas de conclusion.", { size: 10 });

    // Annexes (éditeur de médias)
    if (medias?.length) {
      y -= 8;
      rule();
      text("Annexes", { size: 13, f: bold, color: BLUE, gap: 6 });
      let n = 0;
      for (const md of medias) {
        n++;
        const title = md.annex_title || `Annexe ${n}`;
        const where = [md.step ? STEPS[md.step] : null, md.room].filter(Boolean).join(" — ");
        need(40);
        text(title + (where ? ` · ${where}` : ""), { size: 11, f: bold });
        if (md.media_type === "video") {
          text("Vidéo jointe au dossier (consultable dans l'application).", { size: 9, color: GREY });
        } else {
          try {
            const img = await loadImage(md.file_url);
            const maxW = W - 2 * M, maxH = 300;
            const s = Math.min(maxW / img.width, maxH / img.height);
            const w = img.width * s, h = img.height * s;
            need(h + 8);
            page.drawImage(img, { x: M, y: y - h, width: w, height: h });
            if (md.target_x !== null && md.target_y !== null) {
              const cx = M + w * Number(md.target_x) / 100, cy = y - h * Number(md.target_y) / 100;
              page.drawCircle({ x: cx, y: cy, size: 12, borderColor: RED, borderWidth: 2 });
              page.drawLine({ start: { x: cx - 18, y: cy }, end: { x: cx + 18, y: cy }, thickness: 1.5, color: RED });
              page.drawLine({ start: { x: cx, y: cy - 18 }, end: { x: cx, y: cy + 18 }, thickness: 1.5, color: RED });
            }
            y -= h + 6;
          } catch {
            text("Photo non intégrable (format non pris en charge).", { size: 8, color: GREY });
          }
        }
        if (md.comment) text(md.comment, { size: 10, color: GREY });
        y -= 6;
      }
    }

    // Pied de page
    const pages = pdf.getPages();
    pages.forEach((pg, i) => {
      const f = safe(font, `PLOMI — ${m?.reference ?? ""} — généré le ${fmtDate(new Date().toISOString())} — page ${i + 1}/${pages.length}`);
      pg.drawText(f, { x: M, y: 24, size: 8, font, color: GREY });
    });

    const bytes = await pdf.save();

    // ---- Stockage + traçabilité
    const path = `rapports/${report.mandate_id}/rapport_${report_id}.pdf`;
    const { error: eUp } = await admin.storage.from("documents").upload(path, bytes, { contentType: "application/pdf", upsert: true });
    if (eUp) return json({ error: "Upload impossible : " + eUp.message }, 500);
    const pdfUrl = `${url}/storage/v1/object/public/documents/${path}?v=${Date.now()}`;

    await admin.from("rdf_reports").update({ pdf_url: pdfUrl }).eq("id", report_id);
    await admin.from("documents").delete().eq("report_id", report_id).eq("document_type", "rapport_expertise");
    await admin.from("documents").insert({
      mandate_id: report.mandate_id, report_id, uploaded_by_user_id: userId,
      document_type: "rapport_expertise", file_name: `rapport_${m?.reference ?? report_id}.pdf`,
      file_path: path, mime_type: "application/pdf", file_size: bytes.length, is_public: false,
    });

    // Bucket privé : on renvoie un lien signé valable 7 jours (le lien canonique reste en base)
    const { data: signed } = await admin.storage.from("documents").createSignedUrl(path, SEVEN_DAYS);
    return json({ pdf_url: signed?.signedUrl ?? pdfUrl, stored_url: pdfUrl });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
