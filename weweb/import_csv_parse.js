
// ---------- Outils ----------
// Normalise un nom de colonne : minuscules, sans accents, sans ponctuation.
const normalize = (text) => String(text || '')
  .normalize('NFD').replace(/[̀-ͯ]/g, '')
  .toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

// Table "nom normalisé" -> champ du formulaire.
const lookup = {};
for (const field of FIELDS) {
  const names = [field.label, field.key, field.key.replace('beneficiary.', ''), ...field.aliases];
  for (const name of names) {
    const n = normalize(name);
    if (n && !lookup[n]) lookup[n] = field;
  }
}

// Ouvre le sélecteur de fichier et attend le choix de l'utilisateur.
const pickFile = () => new Promise((resolve) => {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = '.csv,text/csv,text/plain';
  input.style.display = 'none';
  input.addEventListener('change', () => resolve(input.files && input.files[0] ? input.files[0] : null));
  input.addEventListener('cancel', () => resolve(null));
  document.body.appendChild(input);
  input.click();
  setTimeout(() => input.remove(), 60000);
});

// Lit le fichier : UTF-8 d'abord, puis Windows-1252 (export Excel) si des caractères sont illisibles.
const readText = async (file) => {
  const buffer = await file.arrayBuffer();
  let text = new TextDecoder('utf-8').decode(buffer);
  if (text.includes('�')) text = new TextDecoder('windows-1252').decode(buffer);
  return text.replace(/^﻿/, '');
};

// Détecte le séparateur (; , ou tabulation) sur la première ligne.
const detectDelimiter = (text) => {
  const firstLine = text.split(/\r?\n/)[0] || '';
  const counts = { ';': 0, ',': 0, '\t': 0 };
  let inQuotes = false;
  for (const ch of firstLine) {
    if (ch === '"') inQuotes = !inQuotes;
    else if (!inQuotes && ch in counts) counts[ch]++;
  }
  const [best, count] = Object.entries(counts).sort((a, b) => b[1] - a[1])[0];
  return count > 0 ? best : ';';
};

// Découpe le CSV en lignes et cellules (gère les guillemets et les retours à la ligne dans une cellule).
const parseCsv = (text, delimiter) => {
  const rows = []; let row = []; let cell = ''; let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"' && text[i + 1] === '"') { cell += '"'; i++; }
      else if (ch === '"') inQuotes = false;
      else cell += ch;
    } else if (ch === '"') inQuotes = true;
    else if (ch === delimiter) { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      row.push(cell); rows.push(row); row = []; cell = '';
    } else cell += ch;
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
  return rows;
};

// ---------- Conversion des valeurs ----------
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
  const rest = clean.replace(/^\S+/, '');
  const time = rest.match(/(\d{1,2})\s*[:hH]\s*(\d{2})?/);
  const [y, mo, d] = day.split('-').map(Number);
  const h = time ? Number(time[1]) : 9;
  const mi = time ? Number(time[2] || 0) : 0;
  const date = new Date(y, mo - 1, d, h, mi);
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
  if (['visio', 'visioconference', 'video', 'distance', 'adistance'].includes(n) || n.startsWith('visio')) return 'visio';
  if (n === 'rdfs' || n.startsWith('rdfs')) return 'rdfs';
  if (n === 'rdf' || n.startsWith('rdf')) return 'rdf';
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

// ---------- Programme principal ----------
const file = await pickFile();
if (!file) return null; // l'utilisateur a annulé

try {
const text = await readText(file);
const delimiter = detectDelimiter(text);
const table = parseCsv(text, delimiter).filter((r) => r.some((c) => String(c).trim() !== ''));
if (table.length < 2) throw new Error("Le fichier ne contient pas de ligne de données sous l'en-tête.");

// Association des colonnes par nom (et non par position).
const headers = table[0].map((h) => String(h).trim());
const mapping = []; const ignored = []; const used = new Set();
headers.forEach((header, index) => {
  const field = lookup[normalize(header)];
  if (field && !used.has(field.key)) {
    used.add(field.key);
    mapping.push({ index, csv: header, key: field.key, label: field.label, type: field.type });
  } else if (header) {
    ignored.push(field ? `${header} (doublon)` : header);
  }
});
if (!mapping.length) throw new Error("Aucune colonne du fichier ne correspond à un champ du formulaire. Téléchargez le modèle CSV pour voir les noms attendus.");

const seen = {};
const rows = table.slice(1).map((cells, i) => {
  const data = {}; const beneficiary = {}; const fields = []; const errors = []; const warnings = [];

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
    fields.push({ label: col.label, csv: col.csv, value: display || '—', empty: raw === '' });
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
    fields, errors, warnings,
    include: errors.length === 0,
    status: errors.length ? 'error' : 'ready', // ready | error | imported | failed
    message: '',
  };
});

return { fileName: file.name, delimiter, mapping, ignored, rows, importing: false, done: false, error: '' };
} catch (error) {
  // Erreur de lecture : on l'affiche sur la page de prévisualisation.
  return { fileName: file.name, mapping: [], ignored: [], rows: [], importing: false, done: false, error: error.message };
}
