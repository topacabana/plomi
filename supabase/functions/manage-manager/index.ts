// PLOMI — manage-manager (superviseur uniquement)
// POST { action: "create", email, first_name, last_name, phone?, is_supervisor? } -> invitation par e-mail + profil gestionnaire
// POST { action: "update", id, first_name, last_name, phone?, is_supervisor? }    -> RPC supervisor_save_manager
// POST { action: "remove", id }                                                   -> RPC supervisor_remove_manager + blocage de la connexion
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const asUser = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: u } = await asUser.auth.getUser();
    const me = u?.user?.id;
    if (!me) return json({ error: "Utilisateur non connecté" }, 401);
    const { data: isSup } = await asUser.rpc("is_supervisor");
    if (!isSup) return json({ error: "Accès réservé au superviseur" }, 403);

    const first = String(body.first_name ?? "").trim(), last = String(body.last_name ?? "").trim();
    const phone = String(body.phone ?? "").trim() || null;
    const sup = !!body.is_supervisor;

    if (body.action === "create") {
      const email = String(body.email ?? "").trim().toLowerCase();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: "Adresse e-mail invalide" }, 400);
      if (!first || !last) return json({ error: "Le prénom et le nom sont obligatoires" }, 400);

      const { data: meProfile } = await admin.from("user_profiles").select("organization_id").eq("id", me).single();
      const { data: existing } = await admin.from("user_profiles").select("id, removed_at").eq("email", email).maybeSingle();
      if (existing && !existing.removed_at) return json({ error: "Un compte existe déjà avec cette adresse" }, 409);

      let id = existing?.id as string | undefined;
      if (id) {
        // Ancien gestionnaire retiré : on le réactive
        await admin.auth.admin.updateUserById(id, { ban_duration: "none" });
      } else {
        const { data: inv, error: eInv } = await admin.auth.admin.inviteUserByEmail(email, {
          data: { first_name: first, last_name: last, name: `${first} ${last}`, role: "gestionnaire_assurance" },
        });
        if (eInv) return json({ error: "Invitation impossible : " + eInv.message }, 400);
        id = inv.user!.id;
      }
      const { error: eUp } = await admin.from("user_profiles").upsert({
        id, email, first_name: first, last_name: last, phone, role: "gestionnaire_assurance",
        organization_id: meProfile?.organization_id, is_supervisor: sup, account_status: "active",
        removed_at: null, presence_status: "offline", updated_at: new Date().toISOString(),
      });
      if (eUp) return json({ error: eUp.message }, 400);
      await admin.from("activity_logs").insert({
        user_id: me, organization_id: meProfile?.organization_id, entity_type: "user", entity_id: id,
        action: "manager_created", new_values_json: { email, first_name: first, last_name: last, is_supervisor: sup },
      });
      return json({ id, message: existing ? `${first} ${last} est réintégré dans l'équipe.` : `Invitation envoyée à ${email}.` });
    }

    if (body.action === "update") {
      const { error } = await asUser.rpc("supervisor_save_manager", {
        p_id: body.id, p_first_name: first, p_last_name: last, p_phone: phone, p_is_supervisor: sup,
      });
      if (error) return json({ error: error.message }, 400);
      return json({ message: "Gestionnaire modifié" });
    }

    if (body.action === "remove") {
      const { error } = await asUser.rpc("supervisor_remove_manager", { p_id: body.id });
      if (error) return json({ error: error.message }, 400);
      await admin.auth.admin.updateUserById(body.id, { ban_duration: "876000h" });
      return json({ message: "Gestionnaire retiré de l'équipe" });
    }

    return json({ error: "Action inconnue" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
