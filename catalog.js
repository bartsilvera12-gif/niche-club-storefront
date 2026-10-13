export const WA_NUMBER = '595994146975';
export const WA_DISPLAY = '0994 146975';

export const PRODUCTS = [
  { id: 'layton-exclusif', brand: 'Parfums de Marly', name: 'Layton Exclusif', type: 'Nicho', img: 'img/layton-exclusif.jpeg', p5: 150000, p10: 260000, status: 'Disponible' },
  { id: 'creed-aventus', brand: 'Creed', name: 'Aventus', type: 'Nicho', img: 'img/creed-aventus.jpeg', p5: 200000, p10: 360000, status: 'Disponible' },
  { id: 'lv-imagination', brand: 'Louis Vuitton', name: 'Imagination', type: 'Nicho', img: 'img/lv-imagination.jpeg', p5: 215000, p10: 399000, status: 'Disponible' },
  { id: 'lv-limmensite', brand: 'Louis Vuitton', name: "L'Immensité", type: 'Nicho', img: 'img/lv-limmensite.jpeg', p5: 270000, p10: 470000, status: 'Disponible' },
  { id: 'tf-oud-wood', brand: 'Tom Ford', name: 'Oud Wood', type: 'Nicho', img: 'img/tf-oud-wood.jpeg', p5: 180000, p10: 290000, status: 'Disponible' },
  { id: 'tf-costa-azzurra', brand: 'Tom Ford', name: 'Costa Azzurra', type: 'Nicho', img: 'img/tf-costa-azzurra.jpeg', p5: 180000, p10: 300000, status: 'Disponible' },
  { id: 'sauvage-elixir', brand: 'Dior', name: 'Sauvage Elixir', type: 'Diseñador', img: 'img/sauvage-elixir.jpeg', p5: 130000, p10: 190000, status: 'Disponible' },
  { light: true, id: 'ysl-y-edp', brand: 'Yves Saint Laurent', name: 'Y Eau de Parfum', type: 'Diseñador', img: 'img/ysl-y-edp.jpeg', p5: 75000, p10: 130000, status: 'Disponible' },
  { id: 'swy-powerfully', brand: 'Emporio Armani', name: 'Stronger With You Powerfully', type: 'Diseñador', img: 'img/stronger-with-you-powerfully-v2.jpeg', p5: 80000, p10: 150000, status: 'Disponible' },
  { light: true, id: 'power-of-you', brand: 'Emporio Armani', name: 'Power of You', type: 'Diseñador', img: 'img/power-of-you.jpeg', p5: 90000, p10: 130000, status: 'Disponible' },
  { light: true, id: 'adg-profondo', brand: 'Giorgio Armani', name: 'Acqua di Giò Profondo', type: 'Diseñador', img: 'img/acqua-di-gio-profondo.jpeg', p5: 60000, p10: 110000, status: 'Disponible' },
  { light: true, id: 'le-beau-le-parfum', brand: 'Jean Paul Gaultier', name: 'Le Beau Le Parfum', type: 'Diseñador', img: 'img/le-beau-le-parfum.jpeg', p5: 60000, p10: 115000, status: 'Disponible' },
  { light: true, id: 'hawas-malibu', brand: 'Rasasi', name: 'Hawas Malibu', type: 'Árabe', img: 'img/hawas-malibu.jpeg', p5: 35000, p10: 50000, status: 'Disponible' },
  { id: 'hawas-ice', brand: 'Rasasi', name: 'Hawas Ice', type: 'Árabe', img: 'img/hawas-ice-v2.jpeg', p5: 40000, p10: 60000, status: 'Disponible' },
  { light: true, id: 'supremacy-collectors', brand: 'Afnan', name: "Supremacy Collector's Edition", type: 'Árabe', img: 'img/supremacy-collectors.jpeg', p5: 50000, p10: 70000, status: 'Disponible' },
  { id: 'afnan-9pm', brand: 'Afnan', name: '9PM Rebel', type: 'Árabe', img: 'img/afnan-9pm.jpeg', p5: 35000, p10: 50000, status: 'Disponible' },
  { id: 'bharara-king', brand: 'Bharara', name: 'King', type: 'Árabe', img: 'img/bharara-king-v2.jpeg', p5: 50000, p10: 70000, status: 'Disponible' },
  { light: true, id: 'odyssey-aqua', brand: 'Armaf', name: 'Odyssey Aqua Edition', type: 'Árabe', img: 'img/odyssey-aqua.jpeg', p5: 30000, p10: 45000, status: 'Disponible' },
  { light: true, id: 'philos-pura', brand: 'Maison Alhambra', name: 'Philos Pura', type: 'Árabe', img: 'img/philos-pura.jpeg', p5: 35000, p10: 50000, status: 'Disponible' }
];

export const gs = n => 'Gs. ' + Number(n).toLocaleString('de-DE');

export const priceOf = (p, ml) => (ml === 10 ? p.p10 : p.p5);

export const readCart = () => {
  try {
    const raw = localStorage.getItem('nicheclub.cart');
    const cart = raw ? JSON.parse(raw) : [];
    return Array.isArray(cart) ? cart : [];
  } catch (e) { return []; }
};

export const writeCart = cart => {
  try { localStorage.setItem('nicheclub.cart', JSON.stringify(cart)); } catch (e) {}
};

export const waOpen = text => {
  window.open('https://wa.me/' + WA_NUMBER + '?text=' + encodeURIComponent(text), '_blank', 'noopener');
};

export const orderText = (cart, total) => {
  const lines = cart.map(l => {
    const p = PRODUCTS.find(x => x.id === l.id);
    if (!p) return '';
    return '• ' + p.brand + ' ' + p.name + ' — ' + l.ml + ' ml × ' + l.qty + ' — ' + gs(priceOf(p, l.ml) * l.qty);
  }).filter(Boolean).join('\n');
  return 'Hola Niche Club, quiero realizar este pedido:\n\n' + lines + '\n\nTotal: ' + gs(total) + '\n\nNombre:\nCiudad:';
};
