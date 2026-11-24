// Écran « Vérification du compte… » (onload-app) — PLOMI
// Paramètres propres à chaque app : PUBLIQUES, LOGIN_PATH, RPC_ROLE, MSG_VAR, MSG_TEXTE
const PUBLIQUES = ["aa62e2b3-f763-4038-a465-4ed218d83ff2", "b1f54705-d9d8-4566-97c2-38e0428a92e5", "f324774c-f7b1-41db-ad0b-f8dc97d2e082", "da1eb2c8-f030-4cfd-97bf-870427e48095", "bd12f4e9-84f4-44ec-87e7-aa865176237b", "c70be005-42eb-4bc5-ae25-35c0031aa6c6"];
const LOGIN_PATH = '/login';
const RPC_ROLE = 'is_manager';
const MSG_VAR = '6da4a4b1-de1c-4c7b-b690-f7b9127de655';
const MSG_TEXTE = "Ce compte n'est pas un compte mandataire. Connectez-vous sur l'application expert.";
const SB_URL = 'https://ybbzfedbdjgcahqajltm.supabase.co';
const SB_KEY = 'sb_publishable_MkWiAcPv741ROcHpYx3hnw_L-V4EooY'; // clé publique (publishable)

let filet = null;
window.__plomiVerifOk = function () {
  clearTimeout(filet);
  const el = document.getElementById('plomi-verif');
  if (el) el.remove();
};
window.__plomiVerifCover = function () {
  if (document.getElementById('plomi-verif')) return;
  if (!document.getElementById('plomi-verif-style')) {
    const st = document.createElement('style');
    st.id = 'plomi-verif-style';
    st.textContent = '@keyframes plomiTourne{to{transform:rotate(360deg)}}#plomi-verif .roue{width:36px;height:36px;border:4px solid #dbe4f5;border-top-color:#1e3a8a;border-radius:50%;animation:plomiTourne .8s linear infinite}@media (prefers-reduced-motion:reduce){#plomi-verif .roue{animation-duration:2.4s}}#plomi-verif a{color:#1e3a8a;text-decoration:underline}';
    document.head.appendChild(st);
  }
  const ecran = document.createElement('div');
  ecran.id = 'plomi-verif';
  ecran.setAttribute('role', 'status');
  ecran.setAttribute('aria-live', 'polite');
  ecran.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#f8fafc;display:flex;flex-direction:column;gap:16px;align-items:center;justify-content:center;font:500 15px/20px system-ui,sans-serif;color:#1e3a8a;text-align:center;padding:24px';
  const roue = document.createElement('div');
  roue.className = 'roue';
  roue.setAttribute('aria-hidden', 'true');
  const txt = document.createElement('div');
  txt.className = 'txt';
  txt.textContent = 'Vérification du compte…';
  ecran.appendChild(roue);
  ecran.appendChild(txt);
  document.body.appendChild(ecran);
  // Au bout de 10 s : la page reste masquée, on propose de revenir à la connexion
  clearTimeout(filet);
  filet = setTimeout(() => {
    const e = document.getElementById('plomi-verif');
    if (!e) return;
    e.querySelector('.roue')?.remove();
    e.querySelector('.txt').innerHTML = 'Vérification impossible pour le moment.<br><a href="' + LOGIN_PATH + '">Revenir à la connexion</a>';
  }, 10000);
};

function versConnexion(refus) {
  try { if (refus) sessionStorage.setItem('plomiRefus', MSG_TEXTE); } catch (e) {}
  window.location.replace(LOGIN_PATH);
}

// Contrôle autonome (ne dépend pas de l'ordre des workflows) : session puis rôle
async function controler() {
  const sb = wwLib?.wwPlugins?.supabase?.instance;
  if (!sb) return; // le contrôle d'accès WeWeb prendra le relais
  const { data } = await sb.auth.getSession();
  const session = data?.session;
  if (!session) return versConnexion(false);
  const rep = await fetch(SB_URL + '/rest/v1/rpc/' + RPC_ROLE, {
    method: 'POST',
    headers: { apikey: SB_KEY, Authorization: 'Bearer ' + session.access_token, 'Content-Type': 'application/json' },
    body: '{}'
  });
  if (!rep.ok) return; // erreur réseau : l'écran reste, lien de retour après 10 s
  const ok = (await rep.json()) === true;
  if (ok) return window.__plomiVerifOk();
  await sb.auth.signOut();
  versConnexion(true);
}

// Connexion depuis la page de connexion (sans rechargement) : écran posé dès l'ouverture
// de la session, avant l'affichage de la première page privée, puis même contrôle.
let connecte = null;
(async () => {
  const sb = wwLib?.wwPlugins?.supabase?.instance;
  if (!sb) return;
  const { data } = await sb.auth.getSession();
  connecte = !!data?.session;
  sb.auth.onAuthStateChange((evenement, session) => {
    if (evenement === 'SIGNED_OUT') { connecte = false; return; }
    if (evenement === 'SIGNED_IN' && session && connecte === false) {
      connecte = true;
      window.__plomiVerifCover();
      // différé : ne jamais appeler Supabase à l'intérieur du rappel d'authentification
      setTimeout(() => controler().catch(() => {}), 0);
    }
  });
})().catch(() => {});

const publique = PUBLIQUES.includes(globalContext.page?.id);
if (publique) {
  // Page de connexion : afficher le message de refus laissé avant le rechargement
  try {
    const m = sessionStorage.getItem('plomiRefus');
    if (m) { sessionStorage.removeItem('plomiRefus'); wwLib.wwVariable.updateValue(MSG_VAR, m); }
  } catch (e) {}
  return true;
}
window.__plomiVerifCover();
controler().catch(() => {});
return true;
