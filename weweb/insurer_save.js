// Enregistre la fiche assureur : lit les champs, appelle insurer_save et relit la fiche.
// (La géolocalisation de l'adresse et de la ville centre est faite côté serveur.)
const val = (uid) => String(variables[uid + '-value'] ?? '').trim();
const detail = variables['d3a30fad-ac17-4772-a8b0-c13d58fd2e02'] || {};
const ui = variables['a4980631-2826-4c08-ae38-912a9ba43ac9'] || {};

const form = {
  name: val('16e76057-254b-4a45-b717-ed839f6d29f7'),
  address_line_1: val('5752b3f7-91b6-428e-97de-b2c407b20b34'),
  postal_code: val('7a74c8ac-ba24-4155-8202-18ed86b6b380'),
  city: val('87e5fa9b-f057-4347-90a5-a669b5548479'),
  catchment_city: val('90ec12e1-1f8d-4f92-821d-412898b7bfb2'),
  catchment_radius_km: val('4f1d0055-a770-43bf-b370-14d393c935a8'),
  contact_name: val('2cf0b831-6782-4540-a051-7d3f73ff18aa'),
  contact_email: val('17fc67ea-9f98-40f9-a64c-a0bf50d38762'),
  contact_phone: val('8629e8a1-7d77-4db8-b553-ea650d2ae4c4'),
  notes: val('87032167-c6e8-40c7-a458-efb12fb084fc'),
  logo_url: ui.logo_url || '',
};

// Contrôles simples avant envoi
if (!form.name) return { ok: false, error: "Le nom de l'assureur est obligatoire." };
if (form.catchment_city && !form.catchment_radius_km) return { ok: false, error: 'Indiquez le rayon de la zone de chalandise (en km).' };
if (form.catchment_radius_km && !(Number(form.catchment_radius_km) >= 1 && Number(form.catchment_radius_km) <= 1000)) return { ok: false, error: 'Le rayon doit être compris entre 1 et 1000 km.' };
if (form.contact_email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(form.contact_email)) return { ok: false, error: "L'email du contact n'est pas valide." };

// Géolocalisation : faite côté serveur (geocode-addresses, Géoplateforme IGN) dès l'enregistrement.
// insurer_save conserve les coordonnées si l'adresse ne change pas, sinon les remet à zéro
// et un trigger lance le géocodage immédiatement. Plus aucun appel externe depuis le navigateur.

const sb = wwLib.wwPlugins.supabase.instance;
const { data: id, error } = await sb.rpc('insurer_save', { p_id: detail.isNew ? null : detail.id, p_data: form });
if (error) return { ok: false, error: error.message };
const { data: fresh } = await sb.rpc('insurer_detail', { p_id: id });
return { ok: true, id, isNew: !!detail.isNew, detail: fresh };
