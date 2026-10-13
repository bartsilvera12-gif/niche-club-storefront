import { SUPABASE_URL, SUPABASE_SCHEMA, SUPABASE_ANON_KEY } from './supabase-config.js';

// Valores por defecto si Supabase no responde (se editan en /admin → Configuración)
export const DEFAULT_SETTINGS = {
  whatsapp: '595994146975',
  instagram: 'nicheclub.py',
  email: '',
  hero1: 'img/layton-exclusif.jpeg',
  hero2: 'img/bharara-king-portada.jpeg',
  hero3: 'img/creed-aventus.jpeg',
  cta_bg: 'img/coleccion-fondo.jpeg'
};

export const DEFAULT_TYPES = [
  { name: 'Nicho', slug: 'nicho' },
  { name: 'Diseñador', slug: 'disenador' },
  { name: 'Árabe', slug: 'arabes' }
];

export const sbGet = async path => {
  try {
    const r = await fetch(SUPABASE_URL + '/rest/v1/' + path, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + SUPABASE_ANON_KEY, 'Accept-Profile': SUPABASE_SCHEMA },
      cache: 'no-store'
    });
    if (!r.ok) throw new Error(r.status);
    return await r.json();
  } catch (e) {
    return null;
  }
};

// 595994146975 → 0994 146975
export const waDisplay = n => {
  const local = String(n).startsWith('595') ? '0' + String(n).slice(3) : String(n);
  return local.length > 4 ? local.slice(0, 4) + ' ' + local.slice(4) : local;
};

export const loadSite = async () => {
  const [rows, types] = await Promise.all([
    sbGet('settings?select=*&id=eq.1'),
    sbGet('types?select=name,slug&order=position')
  ]);
  const settings = Object.assign({}, DEFAULT_SETTINGS);
  const row = Array.isArray(rows) && rows[0];
  if (row) Object.keys(DEFAULT_SETTINGS).forEach(k => { if (row[k] || k === 'email') settings[k] = row[k] || ''; });
  return {
    settings: Object.assign(settings, {
      waDisplay: waDisplay(settings.whatsapp),
      igUrl: 'https://instagram.com/' + settings.instagram,
      mailto: settings.email ? 'mailto:' + settings.email : ''
    }),
    types: Array.isArray(types) && types.length ? types : DEFAULT_TYPES
  };
};
