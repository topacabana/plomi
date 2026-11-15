// PLOMI — purge-storage : supprime les fichiers mis en file par la base (storage_purge_queue),
// par exemple la photo d'un expert effacé (RGPD, art. 17). Supabase interdit de supprimer un fichier
// de stockage directement en SQL : il faut passer par l'API Storage, d'où cette fonction.
// Appelée toutes les heures par pg_cron avec { token } (jeton du coffre Vault, vérifié en base).
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  let token = "";
  try { token = (await req.json())?.token ?? ""; } catch { /* corps vide */ }
  if (!token) return json({ error: "Jeton manquant" }, 401);

  const { data: items, error } = await db.rpc("storage_purge_pending", { p_token: token, p_limit: 50 });
  if (error) return json({ error: error.message }, 401);

  let done = 0, failed = 0;
  for (const it of (items ?? []) as { id: number; bucket: string; path: string }[]) {
    const { error: err } = await db.storage.from(it.bucket).remove([it.path]);
    await db.rpc("storage_purge_done", { p_token: token, p_id: it.id, p_error: err ? err.message.slice(0, 300) : null });
    err ? failed++ : done++;
  }
  return json({ pending: (items ?? []).length, deleted: done, failed });
});
