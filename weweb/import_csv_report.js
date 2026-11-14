// Rapport d'erreurs de l'import CSV, en PDF, à transmettre à l'assurance.
// Une ligne par ligne du fichier en erreur, en échec ou avec avertissements.
const state = variables['cc405e0c-b8bb-4e05-b18a-90b1b9ffa3c1'] || {};
const raw = state.raw || [];
const problems = (state.rows || []).filter((r) => ['error', 'failed'].includes(r.status) || (r.warnings || []).length);
if (!problems.length) return false;

// Charge jsPDF et son extension de tableaux (une seule fois).
// SRI (audit RGPD A7) : le navigateur refuse le fichier s'il a été modifié sur le CDN.
const loadScript = (src, integrity) => new Promise((resolve, reject) => {
  if (document.querySelector(`script[src="${src}"]`)) return resolve();
  const s = document.createElement('script');
  s.src = src; s.integrity = integrity; s.crossOrigin = 'anonymous'; s.referrerPolicy = 'no-referrer'; s.onload = resolve; s.onerror = () => reject(new Error('Impossible de charger ' + src));
  document.head.appendChild(s);
});
if (!window.jspdf?.jsPDF) await loadScript('https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js',
  'sha512-qZvrmS2ekKPF2mSznTQsxqPgnpkI4DNTlrdUmTzrDgektczlKNRRhy5X5AAOnx5S09ydFYWWNSfcEqDTTHgtNA==');
if (!window.jspdf?.jsPDF?.API?.autoTable) await loadScript('https://cdnjs.cloudflare.com/ajax/libs/jspdf-autotable/3.8.2/jspdf.plugin.autotable.min.js',
  'sha512-2/YdOMV+YNpanLCF5MdQwaoFRVbTmrJ4u4EpqS/USXAQNUDgI5uwYi6J98WVtJKcfe1AbgerygzDFToxAlOGEQ==');
const { jsPDF } = window.jspdf;

// Les polices standard du PDF ne connaissent pas certains signes : on les remplace.
const clean = (text) => String(text ?? '')
  .replace(/«\s*/g, '"').replace(/\s*»/g, '"').replace(/[—–]/g, '-').replace(/…/g, '...').replace(/[’‘]/g, "'").replace(/→/g, '->');

const pad = (n) => String(n).padStart(2, '0');
const now = new Date();
const stamp = `${pad(now.getDate())}/${pad(now.getMonth() + 1)}/${now.getFullYear()} à ${pad(now.getHours())}:${pad(now.getMinutes())}`;
const NAVY = [30, 58, 138]; const RED = [185, 28, 28]; const ORANGE = [180, 83, 9]; const GREY = [100, 116, 139];
const STATUS = { error: 'Non importée', failed: "Échec à l'import", imported: 'Importée (avertissements)', ready: 'Importable (avertissements)' };
const TYPES = { visio: 'Visio', rdf: 'RDF', rdfs: 'RDFS' };

const rejected = problems.filter((r) => ['error', 'failed'].includes(r.status));
const warned = problems.filter((r) => !['error', 'failed'].includes(r.status));

const doc = new jsPDF({ orientation: 'landscape', unit: 'mm', format: 'a4' });
const pageWidth = doc.internal.pageSize.getWidth();

// En-tête
doc.setFont('helvetica', 'bold'); doc.setFontSize(18); doc.setTextColor(...NAVY);
doc.text("Rapport d'erreurs d'import", 14, 18);
doc.setFont('helvetica', 'normal'); doc.setFontSize(10); doc.setTextColor(...GREY);
doc.text(clean(`Fichier : ${state.fileName || '-'}   ·   Généré le ${stamp}`), 14, 25);

// Résumé
doc.setFontSize(11); doc.setTextColor(...NAVY);
doc.text(clean(`${raw.length} ligne(s) dans le fichier`), 14, 34);
doc.setTextColor(...RED); doc.text(clean(`${rejected.length} ligne(s) non importée(s), à corriger et renvoyer`), 80, 34);
doc.setTextColor(...ORANGE); doc.text(clean(`${warned.length} ligne(s) avec des valeurs ignorées`), 190, 34);
let y = 40;
if ((state.missingRequired || []).length) {
  doc.setFontSize(10); doc.setTextColor(...RED);
  doc.text(clean(`Colonnes obligatoires absentes du fichier : ${state.missingRequired.join(', ')}`), 14, y);
  y += 6;
}

// Tableau des lignes concernées
const body = problems.map((row) => {
  const d = row.data || {};
  const errors = [...(row.errors || [])];
  if (row.status === 'failed' && row.message) errors.push(row.message.replace(/^Échec : /, ''));
  return [
    String(row.line),
    clean(row.title),
    clean(row.subtitle || '-'),
    TYPES[d.mandate_type] || '-',
    clean(STATUS[row.status] || row.status),
    clean(errors.map((e) => '• ' + e).join('\n') || '-'),
    clean((row.warnings || []).map((w) => '• ' + w).join('\n') || '-'),
  ];
});
doc.autoTable({
  startY: y,
  head: [['Ligne', 'Bénéficiaire', 'Adresse', 'Type', 'Statut', 'Erreurs (bloquantes)', 'Valeurs ignorées']],
  body,
  theme: 'grid',
  styles: { font: 'helvetica', fontSize: 8.5, cellPadding: 2, valign: 'top', textColor: [30, 41, 59], lineColor: [226, 232, 240] },
  headStyles: { fillColor: NAVY, textColor: 255, fontStyle: 'bold' },
  alternateRowStyles: { fillColor: [248, 250, 252] },
  columnStyles: {
    0: { cellWidth: 13, halign: 'center' }, 1: { cellWidth: 32 }, 2: { cellWidth: 48 }, 3: { cellWidth: 14 },
    4: { cellWidth: 28 }, 5: { cellWidth: 70, textColor: RED }, 6: { cellWidth: 'auto', textColor: ORANGE },
  },
  margin: { left: 14, right: 14 },
  didDrawPage: () => {
    // Pied de page : numéro de page
    doc.setFontSize(8); doc.setTextColor(...GREY);
    doc.text(`Page ${doc.internal.getNumberOfPages()}`, pageWidth - 14, doc.internal.pageSize.getHeight() - 8, { align: 'right' });
    doc.text(clean(`PLOMI · ${state.fileName || ''}`), 14, doc.internal.pageSize.getHeight() - 8);
  },
});

// Note de bas de rapport
const endY = doc.lastAutoTable.finalY + 8;
doc.setFontSize(9); doc.setTextColor(...GREY);
doc.text(clean("Les numéros de ligne correspondent au fichier d'origine (la ligne 1 est l'en-tête). Les lignes « Non importée » doivent être corrigées puis renvoyées ; les valeurs ignorées n'ont pas été reprises dans le mandat."), 14, endY, { maxWidth: pageWidth - 28 });

const base = (state.fileName || 'import').replace(/\.[^.]+$/, '');
doc.save(`rapport_erreurs_${base}_${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}.pdf`);
return true;
