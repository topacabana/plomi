import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 })
  }

  const { address, postal_code, city } = await req.json()

  const fullAddress = `${address}, ${postal_code} ${city}, France`
  const encodedAddress = encodeURIComponent(fullAddress)

  try {
    // Appel API OpenStreetMap (gratuit, pas de clé requise)
    const response = await fetch(
      `https://nominatim.openstreetmap.org/search?format=json&q=${encodedAddress}`,
      { headers: { "User-Agent": "MyApp" } }
    )

    const data = await response.json()

    if (data.length > 0) {
      return new Response(
        JSON.stringify({
          latitude: parseFloat(data[0].lat),
          longitude: parseFloat(data[0].lon)
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    } else {
      return new Response(
        JSON.stringify({ error: "Address not found" }),
        { status: 404, headers: { "Content-Type": "application/json" } }
      )
    }
  } catch (error) {
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    )
  }
})
