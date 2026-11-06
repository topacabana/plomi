// PLOMI — expert-archive-pdf (CC C / D, app expert)
// POST { "report_ids": ["<uuid>", ...], "mode": "view" | "download" | "send" }
// - vérifie que chaque rapport appartient à l'expert connecté
// - fabrique le PDF manquant via generate-report-pdf
// - 1 rapport : lien signé du PDF ; plusieurs : PDF fusionné dans documents/exports/<uid>/
// - download / send : tracé via log_expert_archive_action (base)
// Réponse : { pdf_url, page_count, mail_subject, mail_body }
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { PDFDocument } from "npm:pdf-lib@1.17.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const storagePath = (u: string) => {
  const m = String(u ?? "").split("?")[0].match(/\/storage\/v1\/object\/(?:public|sign|authenticated)\/documents\/(.+)$/);
  return m ? decodeURIComponent(m[1]) : null;
};
const SEVEN_DAYS = 7 * 24 * 3600;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const ids: string[] = Array.isArray(body.report_ids) ? body.report_ids.filter(Boolean) : [];
    const mode: string = ["view", "download", "send"].includes(body.mode) ? body.mode : "view";
    if (!ids.length) return json({ error: "Sélectionnez au moins un mandat" }, 400);

    const url = Deno.env.get("SUPABASE_URL")!;
    const authHeader = req.headers.get("Authorization") ?? "";
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: u } = await asUser.auth.getUser();
    const userId = u?.user?.id;
    if (!userId) return json({ error: "Utilisateur non connecté" }, 401);
    const { data: exp } = await admin.from("experts").select("id,first_name,last_name").eq("user_id", userId).maybeSingle();
    if (!exp) return json({ error: "Aucun profil expert trouvé pour cet utilisateur" }, 403);

    const { data: reports } = await admin.from("rdf_reports").select("id,mandate_id,pdf_url,mandates!inner(reference,assigned_expert_id)").in("id", ids);
    if (!reports || reports.length !== ids.length || reports.some((r: any) => r.mandates?.assigned_expert_id !== exp.id))
      return json({ error: "Archive introuvable" }, 403);

    // PDF manquants : génération par la fonction existante
    for (const r of reports as any[]) {
      if (!r.pdf_url) {
        const res = await fetch(`${url}/functions/v1/generate-report-pdf`, {
          method: "POST",
          headers: { Authorization: authHeader, "Content-Type": "application/json", apikey: Deno.env.get("SUPABASE_ANON_KEY")! },
          body: JSON.stringify({ report_id: r.id }),
        });
        const out = await res.json().catch(() => ({}));
        if (!res.ok) return json({ error: "PDF impossible : " + (out.error ?? res.status) }, 500);
        r.pdf_url = out.stored_url;
      }
    }

    const load = async (r: any) => {
      const p = storagePath(r.pdf_url);
      if (!p) throw new Error("Chemin du PDF inconnu");
      const { data: blob, error } = await admin.storage.from("documents").download(p);
      if (error || !blob) throw new Error("PDF introuvable dans le stockage");
      return { path: p, bytes: new Uint8Array(await blob.arrayBuffer()) };
    };

    const ordered = ids.map((i) => (reports as any[]).find((r) => r.id === i));
    const refs = ordered.map((r) => r.mandates.reference).filter(Boolean);
    const expertName = `${exp.first_name ?? ""} ${exp.last_name ?? ""}`.trim();
    let path: string, pageCount: number, fileName: string;

    if (ordered.length === 1) {
      const f = await load(ordered[0]);
      path = f.path;
      pageCount = (await PDFDocument.load(f.bytes)).getPageCount();
      fileName = `rapport_${refs[0] ?? ordered[0].id}.pdf`;
    } else {
      const out = await PDFDocument.create();
      for (const r of ordered) {
        const src = await PDFDocument.load((await load(r)).bytes);
        (await out.copyPages(src, src.getPageIndices())).forEach((p) => out.addPage(p));
      }
      const bytes = await out.save();
      pageCount = out.getPageCount();
      path = `exports/${userId}/archives_${Date.now()}.pdf`;
      fileName = `rapports_${ordered.length}_mandats.pdf`;
      const { error: eUp } = await admin.storage.from("documents").upload(path, bytes, { contentType: "application/pdf", upsert: true });
      if (eUp) return json({ error: "Upload impossible : " + eUp.message }, 500);
    }

    const { data: signed, error: eS } = await admin.storage.from("documents")
      .createSignedUrl(path, SEVEN_DAYS, mode === "download" ? { download: fileName } : undefined);
    if (eS || !signed) return json({ error: "Lien impossible" }, 500);

    if (mode !== "view") {
      const { error: eL } = await asUser.rpc("log_expert_archive_action", { p_report_ids: ids, p_action: mode === "send" ? "sent" : "downloaded" });
      if (eL) return json({ error: eL.message }, 400);
    }

    const subject = `${refs.join(", ")} - ${expertName}`;
    return json({
      pdf_url: signed.signedUrl,
      page_count: pageCount,
      mail_subject: subject,
      mail_body: `Bonjour,\n\nVeuillez trouver le rapport (${refs.join(", ")}) au lien suivant, valable 7 jours :\n${signed.signedUrl}\n\n${expertName}`,
    });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
