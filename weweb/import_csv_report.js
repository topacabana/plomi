// Rapport d'erreurs de l'import CSV, à transmettre à l'assurance.
// Une ligne par ligne du fichier en erreur, en échec ou avec avertissements :
// numéro de ligne, statut, problèmes, puis les valeurs d'origine du fichier (pour corriger et renvoyer).
const state = variables['cc405e0c-b8bb-4e05-b18a-90b1b9ffa3c1'] || {};
const columns = state.columns || [];
const raw = state.raw || [];
const STATUS = { error: 'Non importée (erreur)', failed: "Échec à l'import", imported: 'Importée avec avertissements', ready: 'Importable avec avertissements' };

const problems = (state.rows || []).filter((r) => ['error', 'failed'].includes(r.status) || (r.warnings || []).length);
if (!problems.length) return false;

// Met une valeur entre guillemets si elle contient un séparateur, un guillemet ou un retour à la ligne.
const quote = (value) => {
  const v = String(value ?? '');
  return /[";\n\r]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
};
const pad = (n) => String(n).padStart(2, '0');
const now = new Date();
const stamp = `${pad(now.getDate())}/${pad(now.getMonth() + 1)}/${now.getFullYear()} ${pad(now.getHours())}:${pad(now.getMinutes())}`;

// Champs obligatoires sans colonne dans le fichier (cause fréquente d'erreur sur toutes les lignes).
const missing = state.missingRequired || [];

const lines = [];
// En-tête du rapport (lignes de contexte, lisibles dans Excel).
lines.push([`Rapport d'erreurs d'import`, state.fileName || ''].map(quote).join(';'));
lines.push([`Généré le`, stamp].map(quote).join(';'));
lines.push([`Lignes du fichier`, raw.length, `Lignes à corriger`, problems.filter((r) => ['error', 'failed'].includes(r.status)).length, `Avec avertissements`, problems.filter((r) => !['error', 'failed'].includes(r.status)).length].map(quote).join(';'));
if (missing.length) lines.push([`Colonnes obligatoires absentes du fichier`, missing.join(', ')].map(quote).join(';'));
lines.push('');

// Tableau : contexte de l'erreur puis toutes les colonnes d'origine.
lines.push(['Ligne du fichier', 'Statut', 'Erreurs', 'Avertissements', ...columns.map((c) => c.csv)].map(quote).join(';'));
for (const row of problems) {
  const cells = raw[row.line - 2] || [];
  const errors = [...(row.errors || [])];
  if (row.status === 'failed' && row.message) errors.push(row.message.replace(/^Échec : /, ''));
  lines.push([row.line, STATUS[row.status] || row.status, errors.join(' | '), (row.warnings || []).join(' | '), ...columns.map((c) => cells[c.index] ?? '')].map(quote).join(';'));
}

// Fichier CSV UTF-8 avec BOM pour qu'Excel affiche correctement les accents.
const base = (state.fileName || 'import').replace(/\.[^.]+$/, '');
const fileName = `rapport_erreurs_${base}_${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}.csv`;
const blob = new Blob(['﻿' + lines.join('\r\n') + '\r\n'], { type: 'text/csv;charset=utf-8' });
const url = URL.createObjectURL(blob);
const link = document.createElement('a');
link.href = url;
link.download = fileName;
document.body.appendChild(link);
link.click();
link.remove();
setTimeout(() => URL.revokeObjectURL(url), 1000);
return true;
