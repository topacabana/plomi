// PG-20 — Géocodage : un HTTP 429 (trop de requêtes) ne doit jamais marquer l'adresse comme refusée.
// Lancement : deno test supabase/functions/geocode-addresses/classement_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { classerReponse } from "./classement.ts";

Deno.test("429 (débit dépassé) : l'adresse reste en attente et sera retentée", () => {
  assertEquals(classerReponse(429), "reessayer");
});

Deno.test("5xx (service indisponible) : retentée", () => {
  for (const s of [500, 502, 503, 504]) assertEquals(classerReponse(s), "reessayer", `HTTP ${s}`);
});

Deno.test("pas de réponse (réseau, délai dépassé) : retentée", () => {
  assertEquals(classerReponse(null), "reessayer");
});

Deno.test("400, 404, 422 : c'est l'adresse qui pose problème", () => {
  for (const s of [400, 404, 422]) assertEquals(classerReponse(s), "adresse", `HTTP ${s}`);
});

Deno.test("200 : réponse exploitable", () => {
  assertEquals(classerReponse(200), "ok");
});
