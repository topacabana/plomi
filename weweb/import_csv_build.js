// Reconstruit les lignes de l'import à partir des colonnes du CSV et du champ choisi pour chacune.
// Appelé après l'analyse du fichier et à chaque changement dans les listes de correspondance.
const state = variables['cc405e0c-b8bb-4e05-b18a-90b1b9ffa3c1'] || {};
const fields = state.fields || [];
const byKey = Object.fromEntries(fields.map((f) => [f.key, f]));

// Colonnes associées à un champ / colonnes ignorées.
const mapping = (state.columns || [])
  .filter((c) => c.key && byKey[c.key])
  .map((c) => ({ ...c, label: byKey[c.key].label, type: byKey[c.key].type }));
const ignored = (state.columns || []).filter((c) => !c.key).map((c) => c.csv);

// Champs obligatoires du formulaire qui n'ont encore aucune colonne.
const REQUIRED = ['mandate_type', 'address_line_1', 'beneficiary.last_name', 'beneficiary.first_name'];
const missingRequired = REQUIRED.filter((k) => !mapping.some((m) => m.key === k)).map((k) => byKey[k]?.label || k);

// ---------- Conversion des valeurs ----------
const normalize = (text) => String(text || '')
  .normalize('NFD').replace(/[̀-ͯ]/g, '')
  .toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const pad = (n) => String(n).padStart(2, '0');

const toDate = (value) => {
  let m = value.match(/^(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2,4})/);
  if (m) { const y = m[3].length === 2 ? '20' + m[3] : m[3]; return `${y}-${pad(m[2])}-${pad(m[1])}`; }
  m = value.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/);
  if (m) return `${m[1]}-${pad(m[2])}-${pad(m[3])}`;
  return null;
};
const toDateTime = (value) => {
  const clean = value.replace('T', ' ').trim();
  const day = toDate(clean);
  if (!day) return null;
  // L'heure est ce qui suit la date (ex. "12/11/2026 14h30") ; 9h00 par défaut.
  const time = clean.replace(/^\S+/, '').match(/(\d{1,2})\s*[:hH]\s*(\d{2})?/);
  const [y, mo, d] = day.split('-').map(Number);
  const date = new Date(y, mo - 1, d, time ? Number(time[1]) : 9, time ? Number(time[2] || 0) : 0);
  return isNaN(date) ? null : date.toISOString();
};
const toBool = (value) => {
  const n = normalize(value);
  if (['oui', 'o', 'yes', 'y', 'true', 'vrai', '1', 'x', 'actif', 'active'].includes(n)) return true;
  if (['non', 'n', 'no', 'false', 'faux', '0', 'inactif'].includes(n)) return false;
  return undefined;
};
const toType = (value) => {
  const n = normalize(value).replace(/ /g, '');
  if (['video', 'distance', 'adistance'].includes(n) || n.startsWith('visio')) return 'visio';
  if (n.startsWith('rdfs')) return 'rdfs';
  if (n.startsWith('rdf')) return 'rdf';
  return null;
};
const toPriority = (value) => {
  const n = normalize(value);
  if (['basse', 'bas', 'faible', 'low', '1'].includes(n)) return 'low';
  if (['moyenne', 'moyen', 'normale', 'normal', 'medium', '2'].includes(n)) return 'medium';
  if (['haute', 'haut', 'elevee', 'eleve', 'high', 'importante', '3'].includes(n)) return 'high';
  if (['critique', 'urgente', 'urgent', 'critical', 'tres urgent', '4'].includes(n)) return 'critical';
  return null;
};
const toPhone = (value) => {
  let p = value.replace(/[^\d+]/g, '');
  if (/^\d{9}$/.test(p)) p = '0' + p; // Excel a supprimé le 0 initial
  return p || null;
};
const TYPE_LABELS = { visio: 'Visio', rdf: 'RDF', rdfs: 'RDFS' };
const PRIORITY_LABELS = { low: 'Basse', medium: 'Moyenne', high: 'Haute', critical: 'Critique' };

// ---------- Une ligne du CSV -> un mandat ----------
const seen = {};
const rows = (state.raw || []).map((cells, i) => {
  const data = {}; const beneficiary = {}; const shown = []; const errors = []; const warnings = [];

  for (const col of mapping) {
    const raw = String(cells[col.index] ?? '').trim();
    let value = null; let display = raw;
    if (raw !== '') {
      if (col.type === 'enum_type') { value = toType(raw); display = value ? TYPE_LABELS[value] : raw; if (!value) errors.push(`Type de mandat inconnu : « ${raw} » (attendu : Visio, RDF ou RDFS)`); }
      else if (col.type === 'enum_priority') { value = toPriority(raw); display = value ? PRIORITY_LABELS[value] : raw; if (!value) warnings.push(`Priorité inconnue ignorée : « ${raw} »`); }
      else if (col.type === 'list') { value = raw.split(/\s*[|;,]\s*/).filter(Boolean); display = value.join(', '); }
      else if (col.type === 'date') { value = toDate(raw); if (!value) warnings.push(`${col.label} illisible ignorée : « ${raw} »`); else display = value.split('-').reverse().join('/'); }
      else if (col.type === 'datetime') { value = toDateTime(raw); if (!value) warnings.push(`${col.label} illisible ignoré : « ${raw} »`); else { const d = new Date(value); display = `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`; } }
      else if (col.type === 'bool') { value = toBool(raw); display = value === undefined ? raw : (value ? 'Oui' : 'Non'); if (value === undefined) { value = null; warnings.push(`${col.label} : « ${raw} » n'est ni oui ni non, ignoré`); } }
      else if (col.type === 'phone') { value = toPhone(raw); display = value || raw; }
      else value = raw;
    }
    if (value !== null && value !== undefined && !(Array.isArray(value) && !value.length)) {
      if (col.key.startsWith('beneficiary.')) beneficiary[col.key.slice(12)] = value;
      else data[col.key] = value;
    }
    shown.push({ label: col.label, csv: col.csv, value: display || '—', empty: raw === '' });
  }

  // Contrôles obligatoires (mêmes règles que le formulaire).
  if (!data.mandate_type && !errors.some((e) => e.startsWith('Type de mandat'))) errors.push('Type de mandat manquant');
  if (!data.address_line_1) errors.push('Adresse manquante');
  if (!beneficiary.last_name) errors.push('Nom du bénéficiaire manquant');
  if (!beneficiary.first_name) errors.push('Prénom du bénéficiaire manquant');

  // Doublon dans le fichier (même bénéficiaire, même adresse).
  const dupKey = normalize([beneficiary.last_name, beneficiary.first_name, data.address_line_1].join(' '));
  if (dupKey && seen[dupKey]) warnings.push(`Doublon probable de la ligne ${seen[dupKey]}`);
  else if (dupKey) seen[dupKey] = i + 2;

  return {
    line: i + 2, // numéro de ligne dans le fichier (l'en-tête est la ligne 1)
    title: [beneficiary.last_name, beneficiary.first_name].filter(Boolean).join(' ') || 'Bénéficiaire non renseigné',
    subtitle: [data.address_line_1, [data.postal_code, data.city].filter(Boolean).join(' ')].filter(Boolean).join(', '),
    data: { ...data, beneficiary },
    fields: shown, errors, warnings,
    include: errors.length === 0,
    status: errors.length ? 'error' : 'ready', // ready | error | imported | failed
    message: '',
  };
});

return { ...state, mapping, ignored, missingRequired, rows };
