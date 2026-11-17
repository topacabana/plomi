// PLOMI — manager-sheet-pdf
// Fiche PDF d'un gestionnaire (page Détails_gestionnaire) : remplace la page HTML
// construite dans le navigateur et imprimée par le JavaScript WeWeb.
// Appel : POST { id }  (JWT de l'utilisateur obligatoire)
// Accès : manager_detail(p_id) est appelé avec les droits de l'utilisateur, donc réservé au
// superviseur et limité à son équipe. Réponse 200 { ok: true, pdf_url } (lien signé 7 jours)
// ou 200 { ok: false, error } (refus lisible par un workflow natif).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from "npm:pdf-lib@1.17.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const refuse = (error: string) => json({ ok: false, error });
const BLUE = rgb(0.118, 0.227, 0.541), GREY = rgb(0.39, 0.45, 0.55), DARK = rgb(0.06, 0.09, 0.16), LINE = rgb(0.88, 0.9, 0.93), TILE = rgb(0.973, 0.98, 0.988);
const TZ = { timeZone: "Europe/Paris" } as const;
const d = (v?: string | null) => v ? new Date(v).toLocaleDateString("fr-FR", TZ) : "–";
const dt = (v?: string | null) => v ? new Date(v).toLocaleString("fr-FR", { ...TZ, dateStyle: "short", timeStyle: "short" }) : "–";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée" }, 405);
  try {
    const p = await req.json().catch(() => ({}));
    if (!p.id) return refuse("Gestionnaire introuvable.");
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: u } = await asUser.auth.getUser();
    const userId = u?.user?.id;
    if (!userId) return json({ ok: false, error: "Utilisateur non connecté" }, 401);

    const { data: m, error } = await asUser.rpc("manager_detail", { p_id: p.id });
    if (error) return refuse(error.message);

    // ---- PDF (portrait A4)
    const pdf = await PDFDocument.create();
    pdf.setTitle(`Fiche gestionnaire - ${m.name ?? ""}`);
    pdf.setAuthor("PLOMI");
    const font = await pdf.embedFont(StandardFonts.Helvetica), bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const safe = (f: PDFFont, t: unknown) => [...String(t ?? "")].map((c) => { try { f.encodeText(c); return c; } catch { return "?"; } }).join("");
    const W = 595.28, H = 841.89, M = 40;
    let page!: PDFPage, y = 0;
    const newPage = () => {
      page = pdf.addPage([W, H]);
      page.drawRectangle({ x: 0, y: H - 56, width: W, height: 56, color: BLUE });
      page.drawText("PLOMI", { x: M, y: H - 34, size: 18, font: bold, color: rgb(1, 1, 1) });
      page.drawText(safe(font, "Fiche gestionnaire"), { x: M + 80, y: H - 33, size: 13, font, color: rgb(1, 1, 1) });
      y = H - 80;
    };
    const ensure = (h: number) => { if (y - h < M + 20) newPage(); };
    const text = (t: unknown, x: number, size = 9.5, f = font, color = DARK) => page.drawText(safe(f, t), { x, y, size, font: f, color });
    const title = (t: string) => {
      ensure(40); y -= 8;
      text(t, M, 12, bold, BLUE); y -= 6;
      page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.6, color: LINE }); y -= 16;
    };
    const tiles = (items: [unknown, string][]) => {
      ensure(48);
      const gap = 8, w = (W - 2 * M - gap * 3) / 4;
      items.forEach(([v, l], i) => {
        const x = M + i * (w + gap);
        page.drawRectangle({ x, y: y - 38, width: w, height: 40, color: TILE });
        page.drawText(safe(bold, v), { x: x + 8, y: y - 16, size: 14, font: bold, color: BLUE });
        page.drawText(safe(font, l), { x: x + 8, y: y - 31, size: 8.5, font, color: GREY });
      });
      y -= 50;
    };
    const table = (head: string[], widths: number[], rows: unknown[][], empty: string) => {
      const draw = (cells: unknown[], f: PDFFont, color: typeof DARK) => {
        let x = M;
        cells.forEach((c, i) => {
          let s = safe(f, c);
          while (s.length > 1 && f.widthOfTextAtSize(s, 8.5) > widths[i] - 6) s = s.slice(0, -2) + "…";
          page.drawText(safe(f, s), { x: x + 3, y, size: 8.5, font: f, color });
          x += widths[i];
        });
        y -= 4; page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.4, color: LINE }); y -= 11;
      };
      ensure(30); draw(head, bold, GREY);
      if (!rows.length) { text(empty, M + 3, 8.5, font, GREY); y -= 15; return; }
      for (const r of rows) { if (y < M + 30) { newPage(); draw(head, bold, GREY); } draw(r, font, DARK); }
    };

    newPage();
    text(`${m.name ?? ""}${m.is_supervisor ? "  (superviseur)" : ""}`, M, 18, bold, BLUE); y -= 18;
    text([m.email, m.phone].filter(Boolean).join("  ·  "), M); y -= 14;
    text(`Membre depuis le ${d(m.created_at)} · Dernière connexion : ${m.last_login_at ? dt(m.last_login_at) : "jamais"} · Fiche éditée le ${dt(new Date().toISOString())}`, M, 8.5, font, GREY);
    y -= 12;

    const h = m.quality?.avg_assign_hours;
    const delai = h == null ? "–" : (h < 1 ? Math.round(h * 60) + " min" : String(Math.round(h * 10) / 10).replace(".", ",") + " h");
    title("Aujourd'hui");
    tiles([[m.today?.actions ?? 0, "Actions"], [m.today?.created ?? 0, "Mandats créés"], [m.today?.drops ?? 0, "Drops"], [m.today?.assignments ?? 0, "Attributions"]]);
    title("Charge en cours");
    tiles([[m.load?.open ?? 0, "Mandats ouverts"], [m.load?.reports ?? 0, "Rapports à valider"], [m.load?.locks ?? 0, "Fiches verrouillées"], ["", ""]]);
    title("Qualité · 30 jours");
    tiles([[delai, "Délai moyen d'attribution"], [m.quality?.redrops ?? 0, "Redrops"], [m.quality?.closed ?? 0, "Clôturés"], [m.quality?.sans_suite ?? 0, "Sans suite"]]);

    const act = (m.activity_14d ?? []) as { day: string; actions: number }[];
    title(`Activité · 14 derniers jours (${act.reduce((s, x) => s + (x.actions || 0), 0)} actions)`);
    const cw = (W - 2 * M) / Math.max(act.length, 1);
    table(act.map((x) => new Date(x.day + "T12:00:00").toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit" })), act.map(() => cw), [act.map((x) => x.actions || 0)], "Aucune activité.");

    const open = (m.open_mandates ?? []) as any[];
    title(`Mandats en cours (${open.length})`);
    table(["Référence", "Ville", "Statut", "Créé le"], [130, 150, 150, 85], open.map((x) => [x.reference, x.city, x.status_label || x.status, d(x.created_at)]), "Aucun mandat en cours.");

    const hist = (m.history_long ?? []) as any[];
    title(`Historique des actions (${hist.length})`);
    table(["Date", "Action", "Motif", "Mandat"], [85, 165, 165, 100], hist.map((x) => [dt(x.at), x.label, x.motif || "", x.reference || ""]), "Aucune action enregistrée.");

    const pages = pdf.getPages();
    pages.forEach((pg, i) => pg.drawText(safe(font, `PLOMI — fiche gestionnaire ${m.name ?? ""} — page ${i + 1}/${pages.length}`), { x: M, y: 18, size: 8, font, color: GREY }));
    const bytes = await pdf.save();

    const slug = String(m.name ?? "gestionnaire").normalize("NFD").replace(/[^\w]+/g, "_").replace(/^_|_$/g, "").toLowerCase();
    const path = `exports/${userId}/fiche_gestionnaire_${slug}_${Date.now()}.pdf`;
    const { error: eUp } = await admin.storage.from("documents").upload(path, bytes, { contentType: "application/pdf", upsert: true });
    if (eUp) return refuse("Enregistrement du PDF impossible : " + eUp.message);
    const { data: sg } = await admin.storage.from("documents").createSignedUrl(path, 7 * 24 * 3600);
    return json({ ok: true, pdf_url: sg?.signedUrl });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message ?? e) }, 500);
  }
});
