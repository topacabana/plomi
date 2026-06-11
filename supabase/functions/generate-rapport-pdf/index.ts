import { serve } from "https://deno.land/std@0.208.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Max-Age": "86400",
};

serve(async (req: Request) => {
  // Preflight CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      status: 200,
      headers: corsHeaders,
    });
  }

  // POST
  if (req.method === "POST") {
    try {
      const { mandate_id } = await req.json();

      if (!mandate_id) {
        return new Response(
          JSON.stringify({ error: "mandate_id required" }),
          {
            status: 400,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          }
        );
      }

      console.log("Processing mandate:", mandate_id);

      // Données fictives pour test
      const mockData = {
        mandate_reference: "TEST-001",
        mandate_date: "11/06/2026",
        defect_type: "Fuite",
        location_address: "123 Rue Test",
        expert_name: "Expert Test",
        expert_email: "expert@test.fr",
        beneficiary_name: "Client Test",
        insurance_name: "Assurance Test",
        generation_date: "11/06/2026",
        generation_time: "12:00:00",
      };

      const html = `<!DOCTYPE html><html><body><h1>Rapport - ${mockData.mandate_reference}</h1><p>Test OK</p></body></html>`;

      return new Response(
        JSON.stringify({
          html: html,
          mandate_reference: mockData.mandate_reference,
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    } catch (error) {
      console.error("Error:", error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }
  }

  return new Response("Method not allowed", {
    status: 405,
    headers: corsHeaders,
  });
});
