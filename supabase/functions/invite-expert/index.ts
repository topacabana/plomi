// PLOMI — invite-expert : le gestionnaire crée un expert.
// 1. vérifie que l'appelant est gestionnaire ; 2. envoie l'invitation e-mail (compte Auth) ;
// 3. crée la fiche via create_expert_record (règles en base) ; annule le compte si la fiche est refusée.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const user = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: { user: me } } = await user.auth.getUser();
    if (!me) return json({ error: "Non connecté" }, 401);
    const { data: isManager } = await user.rpc("is_manager");
    if (!isManager) return json({ error: "Réservé aux gestionnaires" }, 403);

    const body = await req.json();
    const data = body?.data ?? body ?? {};
    const email = String(data.email ?? "").trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "E-mail invalide" }, 400);

    const { data: existing } = await admin.from("user_profiles").select("id").eq("email", email).maybeSingle();
    if (existing) return json({ error: "Un compte existe déjà avec cet e-mail" }, 409);

    const { data: inv, error: invErr } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { role: "expert", first_name: data.first_name ?? "", last_name: data.last_name ?? "" },
      ...(body?.redirect_to ? { redirectTo: body.redirect_to } : {}),
    });
    if (invErr || !inv?.user) return json({ error: invErr?.message ?? "Invitation impossible" }, 400);

    const { data: expertId, error: recErr } = await admin.rpc("create_expert_record", {
      p_manager_id: me.id, p_user_id: inv.user.id, p_data: { ...data, email },
    });
    if (recErr) {
      await admin.auth.admin.deleteUser(inv.user.id);
      return json({ error: recErr.message }, 400);
    }
    return json({ expert_id: expertId, user_id: inv.user.id, invited: email });
  } catch (e) {
    return json({ error: String(e?.message ?? e) }, 500);
  }
});
