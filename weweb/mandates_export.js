// Télécharge les mandats (et leurs rapports) en Excel : onglets « Mandats » et « Rapports ».
// Filtres : période de création (dates du formulaire) et/ou imports cochés ; assureur si fourni.
const C = context.component;
const from = C?.variables?.['b781e542-28f4-40ef-a042-18f3e28c0e13-value'] || null;
const to = C?.variables?.['53f74967-5532-4b07-816c-1d0c07352a04-value'] || null;
const importIds = C?.variables?.['5a8092f5-76c7-4fc3-86d5-3519ebfa992b'] || [];
const insurerId = C?.props?.['e5d42f96-3e3d-44cf-95e6-a8179fc69e38'] || null;
const insurerName = C?.props?.['43b572fc-7b89-4192-9710-7961746981b0'] || '';
if (from && to && from > to) return { error: 'La date de début doit précéder la date de fin.' };

// 1. Données
const { data, error } = await wwLib.wwPlugins.supabase.instance.rpc('mandates_export', {
  p_from: from, p_to: to, p_import_ids: importIds.length ? importIds : null, p_insurer_id: insurerId,
});
if (error) return { error: 'Export impossible : ' + error.message };
const mandates = data?.mandates || [];
const reports = data?.reports || [];
if (!mandates.length) return { error: 'Aucun mandat ne correspond à ces critères.' };

// 2. Bibliothèque Excel (chargée une seule fois)
if (!window.XLSX) {
  await new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js';
    s.onload = resolve; s.onerror = () => reject(new Error("Impossible de charger l'outil Excel."));
    document.head.appendChild(s);
  });
}
const XLSX = window.XLSX;

// Libellés lisibles pour les statuts / priorités
const STATUS = { draft: 'Brouillon', new: 'Nouveau', drop_pending: 'Liste de drop', dropped: 'Sur la carte', assigned: 'Attribué', in_progress: 'En cours',
  waiting_report: 'Rapport à valider', closed: 'Clôturé', cancelled: 'Annulé', suspended: 'Suspendu', planning: 'Planification', redrop: 'Redrop' };
const PRIORITY = { low: 'Basse', medium: 'Moyenne', high: 'Haute', critical: 'Critique' };
// Ordre des colonnes (la base renvoie les champs dans le désordre)
const MAND_COLS = ['Référence', 'N° dossier assureur', 'Assureur', 'Import', 'Statut', 'Type', 'Priorité', 'Nom', 'Prénom',
  'Téléphone mobile', 'Téléphone fixe', 'Email', 'Adresse', 'Complément', 'Code postal', 'Ville', 'Type de lieu', 'Type de résidence', 'Étage',
  'Type de sinistre', 'Type de défaut', 'Pièces', 'Surfaces', 'Description', 'Symptômes', 'Commentaires', 'Expert',
  'Créé le', 'Date prévue', 'Créneau retenu', 'Arrivée sur site', 'Clôturé le', 'Type de clôture'];
const REP_COLS = ['Référence', 'N° dossier assureur', 'Statut rapport', 'Soumis le', 'Validé le', 'Pièce investiguée', 'Infiltration constatée',
  'Moisissure', 'Revêtement endommagé', 'Commentaires inspection', 'Test colorant', 'Test fluorescéine', 'Gaz traceur', 'Gaz traceur – résultat',
  'Sonde – mesure', 'Sonde – unité', 'Sonde – emplacement', 'Hypothèses', 'Conclusions', 'Préconisations / réserves', 'Rapport PDF'];
const REP_STATUS = { draft: 'Brouillon', submitted: 'Soumis', validated: 'Validé', rejected: 'Refusé', accepted: 'Accepté', refused: 'Refusé', transmitted: 'Transmis' };
const ordered = (row, cols) => Object.fromEntries(cols.map((c) => [c, row[c] ?? '']));
const mandRows = mandates.map((m) => ordered({ ...m, 'Statut': STATUS[m['Statut']] || m['Statut'], 'Priorité': PRIORITY[m['Priorité']] || m['Priorité'] }, MAND_COLS));
const repRows = reports.map((r) => ordered({ ...r, 'Statut rapport': REP_STATUS[r['Statut rapport']] || r['Statut rapport'] }, REP_COLS));

// Feuille avec largeurs de colonnes ajustées au contenu et filtre automatique
const sheet = (rows, empty) => {
  const ws = XLSX.utils.json_to_sheet(rows.length ? rows : [{ Information: empty }]);
  const keys = Object.keys(rows[0] || { Information: '' });
  ws['!cols'] = keys.map((k) => ({ wch: Math.min(60, Math.max(k.length, ...rows.slice(0, 200).map((r) => String(r[k] ?? '').length)) + 2) }));
  if (rows.length) ws['!autofilter'] = { ref: ws['!ref'] };
  return ws;
};
const wb = XLSX.utils.book_new();
XLSX.utils.book_append_sheet(wb, sheet(mandRows, 'Aucun mandat'), 'Mandats');
XLSX.utils.book_append_sheet(wb, sheet(repRows, 'Aucun rapport pour ces mandats'), 'Rapports');

// 3. Nom du fichier : mandats_<assureur>_<du>_<au>.xlsx
const slug = (s) => String(s).normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase();
const today = new Date().toISOString().slice(0, 10);
const name = ['mandats', insurerName && slug(insurerName), from || (to ? 'debut' : ''), to || (from ? today : ''), (!from && !to) ? today : '']
  .filter(Boolean).join('_') + '.xlsx';
XLSX.writeFile(wb, name);
return { message: `${mandates.length} mandat(s) et ${reports.length} rapport(s) téléchargés (${name}).` };
