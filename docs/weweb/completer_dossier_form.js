// PLOMI — page publique « Compléter mon dossier » (workflow de page, custom-js, au chargement).
// Rend le formulaire dans #plomi-completion et parle à l'edge function mandate-completion.
// Aucune règle n'est faite confiance côté navigateur : tout est revérifié par completion_submit.
const FN = 'https://ybbzfedbdjgcahqajltm.supabase.co/functions/v1/mandate-completion';
const token = new URLSearchParams(window.location.search).get('t') || '';
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let root = null;
for (let i = 0; i < 40 && !(root = document.getElementById('plomi-completion')); i++) await wait(100);
if (!root) return false;
if (root.dataset.ready) return true;
root.dataset.ready = '1';

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
if (!document.getElementById('plomi-cpl-style')) {
  const st = document.createElement('style');
  st.id = 'plomi-cpl-style';
  st.textContent = `
#plomi-completion{font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#1f2937}
#plomi-completion .card{background:#fff;border:1px solid #e5e7eb;border-radius:14px;padding:22px 20px;margin-bottom:14px}
#plomi-completion .brand{font-size:13px;font-weight:700;letter-spacing:.5px;color:#1e3a8a}
#plomi-completion h1{font-size:21px;color:#1e3a8a;margin:6px 0 10px}
#plomi-completion h2{font-size:16px;color:#1e3a8a;margin:0 0 10px}
#plomi-completion .muted{color:#6b7280;font-size:13px}
#plomi-completion .info{display:grid;grid-template-columns:auto 1fr;gap:4px 12px;font-size:14px;margin-top:8px}
#plomi-completion .info b{color:#374151;font-weight:600}
#plomi-completion label{display:block;font-size:13px;font-weight:600;color:#374151;margin:12px 0 4px}
#plomi-completion input,#plomi-completion select,#plomi-completion textarea{width:100%;box-sizing:border-box;border:1px solid #d1d5db;border-radius:10px;padding:10px 12px;font:inherit;background:#fff;color:#111827}
#plomi-completion textarea{min-height:80px;resize:vertical}
#plomi-completion input:focus,#plomi-completion select:focus,#plomi-completion textarea:focus{outline:2px solid #93c5fd;border-color:#1e3a8a}
#plomi-completion .tabs{display:flex;gap:8px;margin-bottom:14px}
#plomi-completion .tab{flex:1;border:1px solid #1e3a8a;background:#fff;color:#1e3a8a;border-radius:999px;padding:10px 8px;font:600 14px system-ui,sans-serif;cursor:pointer}
#plomi-completion .tab.on{background:#1e3a8a;color:#fff}
#plomi-completion .btn{width:100%;border:0;background:#1e3a8a;color:#fff;border-radius:999px;padding:13px;font:700 15px system-ui,sans-serif;cursor:pointer;margin-top:16px}
#plomi-completion .btn[disabled]{opacity:.6;cursor:wait}
#plomi-completion .err{background:#fef2f2;border:1px solid #fecaca;color:#b91c1c;border-radius:10px;padding:10px 12px;margin-top:12px;font-size:14px}
#plomi-completion .ok{text-align:center}
#plomi-completion .ok .big{font-size:40px}
#plomi-completion .slot{display:flex;align-items:center;gap:10px}
#plomi-completion .slot span{flex:0 0 22px;height:22px;border-radius:50%;background:#e0e7ff;color:#1e3a8a;font:700 12px/22px system-ui;text-align:center}
`;
  document.head.appendChild(st);
}

const call = async (body) => {
  try {
    const r = await fetch(FN, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token, ...body }) });
    return await r.json();
  } catch (e) { return { ok: false, error: 'Connexion impossible. Vérifiez votre réseau et réessayez.' }; }
};
const message = (icon, title, text) => {
  root.innerHTML = `<div class="card ok"><div class="brand">PLOMI</div><div class="big">${icon}</div><h1>${esc(title)}</h1><p>${esc(text)}</p></div>`;
};

root.innerHTML = '<div class="card"><div class="brand">PLOMI</div><p class="muted">Chargement de votre dossier…</p></div>';
if (!token) { message('🔗', 'Lien incomplet', 'Ouvrez le lien reçu par e-mail en entier, ou demandez-en un nouveau à votre assureur.'); return false; }
const d = await call({ action: 'get' });
if (!d || !d.ok) { message(d && d.done ? '✅' : '⚠️', d && d.done ? 'Déjà envoyé' : 'Lien indisponible', (d && d.error) || 'Lien invalide'); return false; }

const LABELS = {
  mobile_phone: ['Téléphone portable', 'tel', '06 12 34 56 78'],
  email: ['Adresse e-mail', 'email', 'vous@exemple.fr'],
  address_line_2: ["Complément d'adresse", 'text', 'Bâtiment, appartement, résidence…'],
  floor: ['Étage', 'text', 'ex. 3e, RDC'],
  entry_code: ["Code d'entrée / digicode", 'text', ''],
  residence_type: ['Type de logement', 'select', ''],
  description: ['Décrivez brièvement le sinistre', 'textarea', 'Ce que vous constatez, depuis quand…'],
};
const pad = (n) => String(n).padStart(2, '0');
const local = (dt) => `${dt.getFullYear()}-${pad(dt.getMonth() + 1)}-${pad(dt.getDate())}T${pad(dt.getHours())}:${pad(dt.getMinutes())}`;
const minDt = new Date(Date.now() + 13 * 3600 * 1000); minDt.setMinutes(minDt.getMinutes() < 30 ? 30 : 60, 0, 0);
const maxDt = new Date(Date.now() + 89 * 24 * 3600 * 1000);
const field = (k) => {
  const [label, type, ph] = LABELS[k] || [k, 'text', ''];
  if (type === 'select') return `<label for="f_${k}">${label}</label><select id="f_${k}" data-k="${k}"><option value="">— Choisir —</option><option>Appartement</option><option>Maison</option><option>Local professionnel</option><option>Autre</option></select>`;
  if (type === 'textarea') return `<label for="f_${k}">${label}</label><textarea id="f_${k}" data-k="${k}" maxlength="500" placeholder="${esc(ph)}"></textarea>`;
  return `<label for="f_${k}">${label}</label><input id="f_${k}" data-k="${k}" type="${type}" maxlength="120" placeholder="${esc(ph)}" ${type === 'tel' ? 'inputmode="tel" autocomplete="tel"' : ''}${type === 'email' ? 'autocomplete="email"' : ''}>`;
};
const missing = Array.isArray(d.missing) ? d.missing : [];

root.innerHTML = `
<div class="card">
  <div class="brand">PLOMI</div>
  <h1>Bonjour ${esc(d.first_name)}, organisons la visite de l'expert</h1>
  <p>${esc(d.insurer ? d.organization + ' pour le compte de ' + d.insurer : d.organization)} a missionné un expert pour votre sinistre.</p>
  <div class="info">
    <b>Dossier</b><span>${esc(d.insurer_file_number || d.reference)}</span>
    <b>Adresse</b><span>${esc(d.address)}</span>
    ${d.sinister ? `<b>Sinistre</b><span>${esc(d.sinister)}</span>` : ''}
  </div>
</div>
<div class="card">
  <div class="tabs" role="tablist">
    <button type="button" class="tab on" data-mode="slots" role="tab">📅 Je propose 3 créneaux</button>
    <button type="button" class="tab" data-mode="callback" role="tab">📞 Je souhaite être rappelé</button>
  </div>
  <div id="p_slots">
    <h2>Vos 3 disponibilités</h2>
    <p class="muted">Entre 7 h et 20 h, au moins 12 heures à l'avance, dans les 3 prochains mois. L'expert retiendra l'un de ces créneaux.</p>
    ${[1, 2, 3].map((i) => `<label for="s${i}">Créneau ${i}</label><div class="slot"><span>${i}</span><input id="s${i}" type="datetime-local" step="1800" min="${local(minDt)}" max="${local(maxDt)}"></div>`).join('')}
    ${missing.length ? `<h2 style="margin-top:22px">Informations complémentaires</h2><p class="muted">Facultatif, mais cela facilite la visite.</p>${missing.map(field).join('')}` : ''}
  </div>
  <div id="p_callback" style="display:none">
    <h2>Être rappelé par votre gestionnaire</h2>
    <label for="c_phone">Numéro à appeler</label><input id="c_phone" type="tel" inputmode="tel" autocomplete="tel" maxlength="20" value="${esc(d.phone || '')}">
    <label for="c_slot">Moment préféré</label><select id="c_slot"><option>Peu importe</option><option>Matin (9 h – 12 h)</option><option>Midi (12 h – 14 h)</option><option>Après-midi (14 h – 18 h)</option></select>
    <label for="c_note">Message (facultatif)</label><textarea id="c_note" maxlength="500" placeholder="Précisez si besoin"></textarea>
  </div>
  <div id="err" class="err" style="display:none" role="alert"></div>
  <button type="button" class="btn" id="send">Envoyer</button>
  <p class="muted" style="text-align:center;margin-top:10px">Lien personnel valable jusqu'au ${esc(new Date(d.expires_at).toLocaleDateString('fr-FR'))}. Vos informations ne servent qu'à l'organisation de l'expertise.</p>
</div>`;

let mode = 'slots';
const $ = (id) => root.querySelector('#' + id);
root.querySelectorAll('.tab').forEach((b) => b.addEventListener('click', () => {
  mode = b.dataset.mode;
  root.querySelectorAll('.tab').forEach((x) => x.classList.toggle('on', x === b));
  $('p_slots').style.display = mode === 'slots' ? '' : 'none';
  $('p_callback').style.display = mode === 'callback' ? '' : 'none';
  $('err').style.display = 'none';
}));
const showErr = (t) => { $('err').textContent = t; $('err').style.display = ''; };

$('send').addEventListener('click', async () => {
  $('err').style.display = 'none';
  let payload;
  if (mode === 'slots') {
    const vals = [1, 2, 3].map((i) => $('s' + i).value);
    if (vals.some((v) => !v)) return showErr('Indiquez vos 3 créneaux.');
    const dates = vals.map((v) => new Date(v));
    if (new Set(vals).size < 3) return showErr('Les 3 créneaux doivent être différents.');
    if (dates.some((x) => x.getHours() < 7 || x.getHours() >= 20)) return showErr('Les créneaux doivent être entre 7 h et 20 h.');
    const fields = {};
    root.querySelectorAll('[data-k]').forEach((el) => { if (el.value.trim()) fields[el.dataset.k] = el.value.trim(); });
    payload = { mode: 'slots', slots: dates.map((x) => x.toISOString()), fields };
  } else {
    const phone = $('c_phone').value.trim();
    if (!phone) return showErr('Indiquez le numéro à appeler.');
    payload = { mode: 'callback', callback_phone: phone, callback_slot: $('c_slot').value, callback_note: $('c_note').value.trim() };
  }
  $('send').disabled = true; $('send').textContent = 'Envoi…';
  const r = await call({ action: 'submit', payload });
  if (r && r.ok) {
    if (r.mode === 'callback') message('📞', 'Demande envoyée', 'Votre gestionnaire va vous rappeler pour convenir du rendez-vous. Merci !');
    else message('✅', 'Merci, c\'est noté !', 'Vos disponibilités ont bien été transmises. Un expert vous confirmera le rendez-vous.');
    return;
  }
  $('send').disabled = false; $('send').textContent = 'Envoyer';
  if (r && r.done) return message('✅', 'Déjà envoyé', r.error);
  showErr((r && r.error) || 'Envoi impossible, réessayez.');
});
return true;
