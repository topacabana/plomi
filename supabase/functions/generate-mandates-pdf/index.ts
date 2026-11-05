// PLOMI — generate-mandates-pdf (F22)
// Fabrique un PDF d'un ou plusieurs mandats (une page par mandat + résumé du rapport s'il existe),
// le range dans documents/exports/ et renvoie un lien signé (7 jours).
// Appel : POST { "mandate_ids": ["<uuid>", ...] }   (JWT obligatoire, gestionnaire_assurance, mandats de son organisation)
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const TYPES: Record<string, string> = { visio: "Visio-expertise", rdf: "RDF", rdfs: "RDFS" };
const STATUS: Record<string, string> = {
  draft: "Brouillon", new: "Nouveau", drop_pending: "En liste de drop", dropped: "Sur la carte",
  redrop: "Redrop", assigned: "Attribué", in_progress: "En cours", waiting_report: "En attente de validation",
  suspended: "Suspendu", closed: "Clôturé", cancelled: "Annulé",
};
const PRIORITY: Record<string, string> = { low: "Basse", medium: "Moyenne", high: "Haute", critical: "Critique" };
const STEPS: Record<number, string> = { 1: "Inspection visuelle", 2: "Colorant et fluorine", 3: "Gaz traceur", 4: "Relevé de sonde" };
const BLUE = rgb(0.118, 0.227, 0.541), GREY = rgb(0.39, 0.45, 0.55), DARK = rgb(0.06, 0.09, 0.16);

const fmt = (d?: string | null, time = true) => {
  if (!d) return "–";
  return new Date(d).toLocaleString("fr-FR", { timeZone: "Europe/Paris", dateStyle: "short", ...(time ? { timeStyle: "short" } : {}) });
};
const list = (v: unknown) => (Array.isArray(v) ? v.join(", ") : (v as string) ?? "");

// Bucket "documents" privé : chemin interne d'un lien public historique, et lien signé temporaire
const storagePath = (u: string) => {
  const m = String(u ?? "").split("?")[0].match(/\/storage\/v1\/object\/(?:public|sign|authenticated)\/documents\/(.+)$/);
  return m ? decodeURIComponent(m[1]) : null;
};
const SEVEN_DAYS = 7 * 24 * 3600;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);
  try {
    const { mandate_ids } = await req.json().catch(() => ({}));
    if (!Array.isArray(mandate_ids) || mandate_ids.length === 0) return json({ error: "mandate_ids manquant" }, 400);
    if (mandate_ids.length > 200) return json({ error: "200 mandats maximum par export" }, 400);

    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: u } = await asUser.auth.getUser();
    const userId = u?.user?.id;
    if (!userId) return json({ error: "Utilisateur non connecté" }, 401);
    const { data: profile } = await admin.from("user_profiles").select("role,organization_id").eq("id", userId).maybeSingle();
    if (profile?.role !== "gestionnaire_assurance") return json({ error: "Réservé aux gestionnaires" }, 403);

    const { data: mandates } = await admin.from("mandates").select("*").in("id", mandate_ids).eq("insurance_org_id", profile.organization_id).order("reference");
    if (!mandates?.length) return json({ error: "Aucun mandat trouvé" }, 404);

    const ids = (k: string) => [...new Set(mandates.map((m: any) => m[k]).filter(Boolean))];
    const [{ data: bens }, { data: exps }, { data: orgs }, { data: reports }] = await Promise.all([
      admin.from("beneficiaries").select("id,first_name,last_name,mobile_phone,landline_phone,email").in("id", ids("beneficiary_id")),
      admin.from("experts_with_profiles").select("id,first_name,last_name,company_name,phone,email").in("id", ids("assigned_expert_id")),
      admin.from("organizations").select("id,name").in("id", ids("insurance_org_id")),
      admin.from("rdf_reports").select("id,mandate_id,status,submitted_at,rapport_conclusions,pdf_url").in("mandate_id", mandates.map((m: any) => m.id)).neq("status", "draft").order("submitted_at", { ascending: false }),
    ]);
    const reportIds = (reports ?? []).map((r: any) => r.id);
    const { data: rooms } = reportIds.length
      ? await admin.from("rdf_report_rooms").select("report_id,step,room,infiltration,gaz_detecte,sonde_type,sonde_percent").in("report_id", reportIds).order("step").order("position")
      : { data: [] as any[] };
    const by = (arr: any[] | null, id: string) => (arr ?? []).find((x) => x.id === id);

    // ---- PDF
    const pdf = await PDFDocument.create();
    pdf.setTitle(mandates.length === 1 ? `Mandat ${mandates[0].reference}` : `Mandats (${mandates.length})`);
    pdf.setAuthor("PLOMI");
    const font = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const safe = (f: PDFFont, s: string) =>
      [...String(s ?? "")].map((c) => { try { f.encodeText(c); return c; } catch { return "?"; } }).join("");

    const W = 595.28, H = 841.89, M = 48;
    let page!: PDFPage, y = 0;
    const need = (h: number) => { if (y - h < M + 20) { page = pdf.addPage([W, H]); y = H - M; } };
    const wrap = (s: string, f: PDFFont, size: number, maxW: number) => {
      const out: string[] = [];
      for (const para of String(s ?? "").split(/\r?\n/)) {
        let line = "";
        for (const w of safe(f, para).split(/\s+/)) {
          const t = line ? line + " " + w : w;
          if (f.widthOfTextAtSize(t, size) > maxW && line) { out.push(line); line = w; } else line = t;
        }
        out.push(line);
      }
      return out;
    };
    const text = (s: string, o: { size?: number; f?: PDFFont; color?: any; gap?: number } = {}) => {
      const size = o.size ?? 10, f = o.f ?? font;
      for (const l of wrap(s, f, size, W - 2 * M)) { need(size + 4); page.drawText(l, { x: M, y: y - size, size, font: f, color: o.color ?? DARK }); y -= size + (o.gap ?? 4); }
    };
    const kv = (k: string, v: string) => {
      const lines = wrap(v || "–", font, 9.5, W - 2 * M - 130);
      need(13 * lines.length + 1);
      page.drawText(safe(bold, k), { x: M, y: y - 10, size: 9.5, font: bold, color: GREY });
      lines.forEach((l) => { page.drawText(l, { x: M + 130, y: y - 10, size: 9.5, font, color: DARK }); y -= 13; });
      y -= 1;
    };
    const section = (t: string) => { y -= 6; text(t, { size: 12, f: bold, color: BLUE, gap: 5 }); };

    for (const m of mandates as any[]) {
      page = pdf.addPage([W, H]);
      page.drawRectangle({ x: 0, y: H - 70, width: W, height: 70, color: BLUE });
      page.drawText("PLOMI", { x: M, y: H - 42, size: 22, font: bold, color: rgb(1, 1, 1) });
      page.drawText(safe(font, "Fiche mandat"), { x: M, y: H - 60, size: 11, font, color: rgb(0.85, 0.89, 1) });
      const ref = safe(bold, m.reference ?? "");
      page.drawText(ref, { x: W - M - bold.widthOfTextAtSize(ref, 14), y: H - 42, size: 14, font: bold, color: rgb(1, 1, 1) });
      y = H - 88;

      const ben = by(bens, m.beneficiary_id), exp = by(exps, m.assigned_expert_id), org = by(orgs, m.insurance_org_id);
      section("Mandat");
      kv("Référence", m.reference);
      if (m.title) kv("Intitulé", m.title);
      kv("Type", TYPES[m.mandate_type] ?? m.mandate_type);
      kv("Statut", STATUS[m.status] ?? m.status);
      kv("Priorité", PRIORITY[m.priority] ?? m.priority);
      kv("Mandataire", org?.name ?? "–");
      kv("Créé le", fmt(m.created_at));
      if (m.redrop_count) kv("Redrops", String(m.redrop_count));

      section("Sinistre");
      kv("Type de sinistre", list(m.sinister_type));
      kv("Date du sinistre", fmt(m.incident_date));
      kv("Pièces touchées", list(m.affected_rooms));
      kv("Surfaces touchées", list(m.affected_surfaces));
      if (m.defect_type) kv("Défaut", m.defect_type);
      if (m.symptoms) kv("Symptômes", m.symptoms);
      if (m.comments) kv("Commentaires", m.comments);

      section("Lieu");
      kv("Adresse", [m.address_line_1, m.address_line_2, [m.postal_code, m.city].filter(Boolean).join(" ")].filter(Boolean).join(", "));
      kv("Logement", [m.location_type, m.residence_type, m.floor ? `étage ${m.floor}` : ""].filter(Boolean).join(" · "));
      if (m.entry_code) kv("Code d'entrée", m.entry_code);

      section("Bénéficiaire");
      kv("Nom", ben ? `${ben.first_name ?? ""} ${ben.last_name ?? ""}`.trim() : "–");
      kv("Téléphone", ben ? [ben.mobile_phone, ben.landline_phone].filter(Boolean).join(" · ") : "–");
      if (ben?.email) kv("Email", ben.email);
      if (m.secondary_contact_last_name) kv("Contact secondaire", `${m.secondary_contact_first_name ?? ""} ${m.secondary_contact_last_name} ${m.secondary_contact_mobile ?? ""}`.trim());

      section("Intervention");
      const slots = [m.slot_1_at, m.slot_2_at, m.slot_3_at].filter(Boolean).map((s: string) => fmt(s)).join(" · ");
      kv("Créneaux proposés", slots || "–");
      kv("Créneau retenu", fmt(m.selected_slot_at));
      kv("Expert", exp ? `${exp.first_name ?? ""} ${exp.last_name ?? ""}`.trim() + (exp.company_name ? ` — ${exp.company_name}` : "") : "Non attribué");
      if (exp?.phone) kv("Tél. expert", exp.phone);
      kv("Diffusé le", fmt(m.drop_at));
      kv("Attribué le", fmt(m.assigned_at));
      kv("Démarré le", fmt(m.started_at));
      if (m.closed_at) kv("Clôturé le", fmt(m.closed_at));
      if (m.motif_abandon) kv("Dernier motif", m.motif_abandon);

      const rep = (reports ?? []).find((r: any) => r.mandate_id === m.id);
      section("Rapport de l'expert");
      if (!rep) text("Aucun rapport reçu.", { color: GREY });
      else {
        kv("Statut", rep.status === "validated" ? "Validé" : "Envoyé, en attente de validation");
        kv("Envoyé le", fmt(rep.submitted_at));
        const rr = (rooms ?? []).filter((x: any) => x.report_id === rep.id);
        for (const x of rr) {
          const c: string[] = [];
          if (x.step <= 2 && x.infiltration !== null) c.push(x.infiltration ? "infiltration constatée" : "infiltration non constatée");
          if (x.step === 3 && x.gaz_detecte !== null) c.push(x.gaz_detecte ? "gaz détecté" : "gaz non détecté");
          if (x.sonde_type) c.push(`sonde ${x.sonde_type === "picot" ? "à picot" : "à boule"} ${x.sonde_percent ?? "–"} %`);
          kv(STEPS[x.step] ?? `Étape ${x.step}`, `${x.room}${c.length ? " — " + c.join(", ") : ""}`);
        }
        if (rep.rapport_conclusions) kv("Conclusion", rep.rapport_conclusions);
        if (rep.pdf_url) {
          const sp = storagePath(rep.pdf_url);
          const { data: sg } = sp ? await admin.storage.from("documents").createSignedUrl(sp, SEVEN_DAYS) : { data: null };
          kv("Rapport complet", sg?.signedUrl ?? rep.pdf_url.split("?")[0]);
        }
      }
    }

    const pages = pdf.getPages();
    const stamp = fmt(new Date().toISOString());
    pages.forEach((pg, i) => pg.drawText(safe(font, `PLOMI — export du ${stamp} — page ${i + 1}/${pages.length}`), { x: M, y: 24, size: 8, font, color: GREY }));
    const bytes = await pdf.save();

    const name = mandates.length === 1 ? `mandat_${mandates[0].reference}` : `mandats_${mandates.length}`;
    const path = `exports/${userId}/${name}_${Date.now()}.pdf`;
    const { error: eUp } = await admin.storage.from("documents").upload(path, bytes, { contentType: "application/pdf", upsert: true });
    if (eUp) return json({ error: "Upload impossible : " + eUp.message }, 500);

    await admin.from("activity_logs").insert({
      user_id: userId, entity_type: "document", entity_id: mandates[0].id, action: "mandates_pdf_export",
      new_values_json: { mandate_ids: mandates.map((m: any) => m.id), path, count: mandates.length },
    });

    // Bucket privé : lien signé valable 7 jours (utilisé aussi dans le mail)
    const { data: sg } = await admin.storage.from("documents").createSignedUrl(path, SEVEN_DAYS);
    const pdfUrl = sg?.signedUrl ?? `${url}/storage/v1/object/public/documents/${path}`;
    const refs = mandates.map((m: any) => m.reference);
    // Objet du mail (doc MVP) : identifiant + genre (type de mandat) + nom du bénéficiaire
    const m0: any = mandates[0], b0 = by(bens, m0.beneficiary_id);
    const subject = mandates.length === 1
      ? [m0.reference, TYPES[m0.mandate_type] ?? m0.mandate_type, b0?.last_name].filter(Boolean).join(" – ")
      : `Mandats PLOMI – ${mandates.length} dossiers (${refs.slice(0, 5).join(", ")}${refs.length > 5 ? "…" : ""})`;
    return json({ pdf_url: pdfUrl, count: mandates.length, references: refs, subject });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
