
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

// ---------- Programme principal ----------
const file = await pickFile();
if (!file) return null; // l'utilisateur a annulé

// Liste des champs du formulaire, réutilisée par la page de prévisualisation (listes de correspondance).
const fields = FIELDS.map(({ key, label, type }) => ({ key, label, type }));

try {
  const text = await readText(file);
  const delimiter = detectDelimiter(text);
  const table = parseCsv(text, delimiter).filter((r) => r.some((c) => String(c).trim() !== ''));
  if (table.length < 2) throw new Error("Le fichier ne contient pas de ligne de données sous l'en-tête.");

  // Association automatique des colonnes par nom (et non par position).
  // Une colonne non reconnue reste vide : elle pourra être associée à la main sur la page suivante.
  const raw = table.slice(1);
  const used = new Set();
  const columns = table[0].map((header, index) => {
    const csv = String(header).trim() || `Colonne ${index + 1}`;
    const field = lookup[normalize(csv)];
    let key = '';
    if (field && !used.has(field.key)) { used.add(field.key); key = field.key; }
    const sample = raw.map((r) => String(r[index] ?? '').trim()).find(Boolean) || '';
    return { index, csv, key, auto: !!key, sample };
  });

  return { fileName: file.name, delimiter, fields, columns, raw, rows: [], importing: false, done: false, error: '' };
} catch (error) {
  // Erreur de lecture : on l'affiche sur la page de prévisualisation.
  return { fileName: file.name, fields, columns: [], raw: [], rows: [], importing: false, done: false, error: error.message };
}
