// PLOMI — Classement de la réponse HTTP de la Géoplateforme (géocodage).
// Isolé dans ce module pour être testé unitairement (classement_test.ts, PG-20).
//
//   « reessayer » : service indisponible ou débit dépassé (5xx, 429, pas de réponse réseau).
//                   On n'écrit rien : l'adresse reste en attente et sera retentée au prochain passage.
//   « adresse »   : la requête a été refusée pour une raison liée à l'adresse (autres 4xx).
//                   L'adresse est marquée « refusée par le service ».
//   « ok »        : réponse exploitable (2xx).
export type Classement = "reessayer" | "adresse" | "ok";

export function classerReponse(status: number | null): Classement {
  if (status === null) return "reessayer";
  if (status === 429 || status >= 500) return "reessayer";
  if (status >= 200 && status < 300) return "ok";
  return "adresse";
}
