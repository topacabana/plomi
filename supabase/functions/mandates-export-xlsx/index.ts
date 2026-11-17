// PLOMI — mandates-export-xlsx
// Fichier Excel des mandats et de leurs rapports (popup « Téléchargement mandats ») : onglets « Mandats » et « Rapports ».
// Remplace la génération dans le navigateur (bibliothèque XLSX chargée depuis un CDN) par le JavaScript WeWeb.
// Appel : POST { from?, to?, import_ids?, insurer_id?, insurer_name? }  (JWT de l'utilisateur obligatoire)
// Données : mandates_export(...) appelé avec les droits de l'utilisateur (RLS, organisation du gestionnaire).
// Réponse : 200 { ok: true, url, file_name, message } (lien signé 7 jours) ou 200 { ok: false, error }.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import * as XLSX from "npm:xlsx@0.18.5";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const refuse = (error: string) => json({ ok: false, error });

const STATUS: Record<string, string> = { draft: "Brouillon", new: "Nouveau", drop_pending: "Liste de drop", dropped: "Sur la carte", assigned: "Attribué",
  in_progress: "En cours", waiting_report: "Rapport à valider", closed: "Clôturé", cancelled: "Annulé", suspended: "Suspendu", planning: "Planification", redrop: "Redrop" };
const PRIORITY: Record<string, string> = { low: "Basse", medium: "Moyenne", high: "Haute", critical: "Critique" };
const REP_STATUS: Record<string, string> = { draft: "Brouillon", submitted: "Soumis", validated: "Validé", rejected: "Refusé", accepted: "Accepté", refused: "Refusé", transmitted: "Transmis" };
const MAND_COLS = ["Référence", "N° dossier assureur", "Assureur", "Import", "Statut", "Type", "Priorité", "Nom", "Prénom",
  "Téléphone mobile", "Téléphone fixe", "Email", "Adresse", "Complément", "Code postal", "Ville", "Type de lieu", "Type de résidence", "Étage",
  "Type de sinistre", "Type de défaut", "Pièces", "Surfaces", "Description", "Symptômes", "Commentaires", "Expert",
  "Créé le", "Date prévue", "Créneau retenu", "Arrivée sur site", "Clôturé le", "Type de clôture"];
const REP_COLS = ["Référence", "N° dossier assureur", "Statut rapport", "Soumis le", "Validé le", "Pièce investiguée", "Infiltration constatée",
  "Moisissure", "Revêtement endommagé", "Commentaires inspection", "Test colorant", "Test fluorescéine", "Gaz traceur", "Gaz traceur – résultat",
  "Sonde – mesure", "Sonde – unité", "Sonde – emplacement", "Hypothèses", "Conclusions", "Préconisations / réserves", "Rapport PDF"];

type Row = Record<string, unknown>;
const ordered = (row: Row, cols: string[]) => Object.fromEntries(cols.map((c) => [c, row[c] ?? ""]));
const slug = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^A-Za-z0-9]+/g, "-").replace(/^-|-$/g, "").toLowerCase();
const isDate = (v: unknown) => typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v);

// Feuille avec largeurs de colonnes ajustées au contenu et filtre automatique
const sheet = (rows: Row[], empty: string) => {
  const ws = XLSX.utils.json_to_sheet(rows.length ? rows : [{ Information: empty }]);
  const keys = Object.keys(rows[0] ?? { Information: "" });
  ws["!cols"] = keys.map((k) => ({ wch: Math.min(60, Math.max(k.length, ...rows.slice(0, 200).map((r) => String(r[k] ?? "").length)) + 2) }));
  if (rows.length && ws["!ref"]) ws["!autofilter"] = { ref: ws["!ref"] };
  return ws;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée" }, 405);
  try {
    const p = await req.json().catch(() => ({}));
    const from = isDate(p.from) ? p.from : null;
    const to = isDate(p.to) ? p.to : null;
    if (from && to && from > to) return refuse("La date de début doit précéder la date de fin.");
    const importIds = Array.isArray(p.import_ids) ? p.import_ids.map(String).filter(Boolean) : [];

    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: u } = await asUser.auth.getUser();
    const userId = u?.user?.id;
    if (!userId) return json({ ok: false, error: "Utilisateur non connecté" }, 401);

    const { data, error } = await asUser.rpc("mandates_export", {
      p_from: from, p_to: to, p_import_ids: importIds.length ? importIds : null, p_insurer_id: p.insurer_id || null,
    });
    if (error) return refuse("Export impossible : " + error.message);
    const mandates = (data?.mandates ?? []) as Row[];
    const reports = (data?.reports ?? []) as Row[];
    if (!mandates.length) return refuse("Aucun mandat ne correspond à ces critères.");

    const mandRows = mandates.map((m) => ordered({ ...m, "Statut": STATUS[m["Statut"] as string] ?? m["Statut"], "Priorité": PRIORITY[m["Priorité"] as string] ?? m["Priorité"] }, MAND_COLS));
    const repRows = reports.map((r) => ordered({ ...r, "Statut rapport": REP_STATUS[r["Statut rapport"] as string] ?? r["Statut rapport"] }, REP_COLS));
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, sheet(mandRows, "Aucun mandat"), "Mandats");
    XLSX.utils.book_append_sheet(wb, sheet(repRows, "Aucun rapport pour ces mandats"), "Rapports");
    const bytes = XLSX.write(wb, { type: "array", bookType: "xlsx" }) as ArrayBuffer;

    // Nom du fichier : mandats_<assureur>_<du>_<au>.xlsx
    const today = new Date().toISOString().slice(0, 10);
    const insurerName = String(p.insurer_name ?? "");
    const fileName = ["mandats", insurerName && slug(insurerName), from || (to ? "debut" : ""), to || (from ? today : ""), (!from && !to) ? today : ""]
      .filter(Boolean).join("_") + ".xlsx";

    const path = `exports/${userId}/${Date.now()}_${fileName}`;
    const { error: eUp } = await admin.storage.from("documents").upload(path, new Uint8Array(bytes), {
      contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", upsert: true,
    });
    if (eUp) return refuse("Enregistrement du fichier impossible : " + eUp.message);
    const { data: sg } = await admin.storage.from("documents").createSignedUrl(path, 7 * 24 * 3600);
    return json({ ok: true, url: sg?.signedUrl, file_name: fileName,
      message: `${mandates.length} mandat(s) et ${reports.length} rapport(s) téléchargés (${fileName}).` });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message ?? e) }, 500);
  }
});
