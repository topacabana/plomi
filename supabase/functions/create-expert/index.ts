// Edge Function: create-expert
// Centralise en un seul appel : vérification doublon + géocodage + insertion
// Remplace l'enchaînement Select / Edge Function / Insert fait côté frontend WeWeb

import { createClient } from "jsr:@supabase/supabase-js@2"

Deno.serve(async (req: Request) => {
  // CORS basique pour les appels depuis WeWeb
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    })
  }

  try {
    const body = await req.json()
    const {
      first_name,
      last_name,
      email,
      phone,
      address_line_1,
      address_line_2,
      postal_code,
      city,
      coverage_zone,
      photo_url,
      organization_id,
      company_name,
    } = body

    // Validation minimale des champs obligatoires
    // organization_id et company_name sont obligatoires en base (contraintes NOT NULL sur experts)
    if (!first_name || !last_name || !email || !address_line_1 || !postal_code || !city || !organization_id || !company_name) {
      return new Response(
        JSON.stringify({ error: "Champs obligatoires manquants (first_name, last_name, email, address_line_1, postal_code, city, organization_id, company_name)" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      )
    }

    // Client Supabase avec la clé Service Role (auto-injectée par Supabase, jamais exposée côté client)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    )

    // 1. Vérification du doublon par email (table experts)
    const { data: existing, error: selectError } = await supabase
      .from("experts")
      .select("id")
      .eq("email", email)
      .maybeSingle()

    if (selectError) {
      return new Response(
        JSON.stringify({ error: "Erreur lors de la vérification du doublon", details: selectError.message }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      )
    }

    if (existing) {
      return new Response(
        JSON.stringify({ error: "Expert existant", code: "DUPLICATE_EMAIL" }),
        { status: 409, headers: { "Content-Type": "application/json" } }
      )
    }

    // 2. Création du compte via invitation par email (auth.users)
    // Le trigger "on_auth_user_created" crée automatiquement la ligne user_profiles associée
    // (lecture des métadonnées first_name / last_name / role)
    const { data: inviteData, error: inviteError } = await supabase.auth.admin.inviteUserByEmail(
      email,
      {
        data: {
          first_name,
          last_name,
          role: "expert",
        },
      }
    )

    if (inviteError || !inviteData?.user) {
      // Compte déjà existant côté Auth (mais pas encore d'expert associé) ou autre erreur d'invitation
      const isAlreadyRegistered = inviteError?.message?.toLowerCase().includes("already registered")
      return new Response(
        JSON.stringify({
          error: isAlreadyRegistered ? "Compte déjà existant" : "Erreur lors de la création du compte",
          code: isAlreadyRegistered ? "DUPLICATE_EMAIL" : "AUTH_ERROR",
          details: inviteError?.message,
        }),
        { status: isAlreadyRegistered ? 409 : 500, headers: { "Content-Type": "application/json" } }
      )
    }

    const userId = inviteData.user.id

    // 3. Complément du profil (organization_id, account_status) — non fourni par le trigger par défaut
    const { error: profileUpdateError } = await supabase
      .from("user_profiles")
      .update({
        organization_id,
        account_status: "pending_validation",
        phone,
      })
      .eq("id", userId)

    if (profileUpdateError) {
      // Rollback : suppression du compte auth (cascade automatique sur user_profiles)
      await supabase.auth.admin.deleteUser(userId)
      return new Response(
        JSON.stringify({ error: "Erreur lors de la mise à jour du profil", details: profileUpdateError.message }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      )
    }

    // 4. Géocodage de l'adresse via Nominatim (OpenStreetMap) — non bloquant
    const fullAddress = `${address_line_1}, ${postal_code} ${city}, France`
    let latitude: number | null = null
    let longitude: number | null = null

    const geoResponse = await fetch(
      `https://nominatim.openstreetmap.org/search?format=json&q=${encodeURIComponent(fullAddress)}`,
      { headers: { "User-Agent": "PLOMI/1.0" } }
    )
    const geoData = await geoResponse.json()

    if (geoData.length > 0) {
      latitude = parseFloat(geoData[0].lat)
      longitude = parseFloat(geoData[0].lon)
    }
    // Si le géocodage échoue, on n'interrompt pas la création : latitude/longitude restent null

    // 5. Insertion de l'expert, lié au compte créé
    const { data: newExpert, error: insertError } = await supabase
      .from("experts")
      .insert({
        user_id: userId,
        first_name,
        last_name,
        email,
        phone,
        address_line_1,
        address_line_2,
        postal_code,
        city,
        latitude,
        longitude,
        coverage_zone,
        photo_url,
        organization_id,
        company_name,
        status_experts: "new",
      })
      .select()
      .single()

    if (insertError) {
      // Rollback : suppression du compte auth (cascade automatique sur user_profiles)
      await supabase.auth.admin.deleteUser(userId)
      return new Response(
        JSON.stringify({ error: "Erreur lors de la création de l'expert", details: insertError.message }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      )
    }

    return new Response(
      JSON.stringify({ success: true, expert: newExpert }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    )
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Erreur inattendue", details: err instanceof Error ? err.message : String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    )
  }
})
