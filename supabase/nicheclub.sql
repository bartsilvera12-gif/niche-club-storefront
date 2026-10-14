-- Niche Club — catálogo y panel de administración en Supabase
-- Correr en el SQL Editor de Supabase Studio. Se puede volver a correr sin perder datos.
-- Antes: crear el usuario admin@nicheclubpy.com en Authentication → Users (ver paso 8 al final).
-- Todo vive en el schema nicheclubweb para no mezclarse con otros proyectos del servidor.

-- 0. Schema ---------------------------------------------------------------
-- La API (PostgREST) solo publica los schemas listados en PGRST_DB_SCHEMAS.
-- En el .env del Supabase self-hosted, agregar nicheclubweb a la lista existente
-- y reiniciar el contenedor rest (docker compose up -d rest).

create schema if not exists nicheclubweb;
grant usage on schema nicheclubweb to anon, authenticated, service_role;

-- 1. Tablas ---------------------------------------------------------------

create table if not exists nicheclubweb.products (
  id         text primary key check (id ~ '^[a-z0-9-]+$'),
  brand      text not null check (length(trim(brand)) between 1 and 120),
  name       text not null check (length(trim(name)) between 1 and 120),
  type       text not null,
  img        text not null check (length(img) between 1 and 500),
  p5         integer not null check (p5 > 0),
  p10        integer not null check (p10 > 0),
  status     text not null default 'Disponible' check (status in ('Disponible', 'Agotado', 'Por encargo')),
  visible    boolean not null default true,
  light      boolean not null default false,
  position   integer not null default 0,
  updated_at timestamptz not null default now()
);
-- Los tipos ahora salen de la tabla types
alter table nicheclubweb.products drop constraint if exists products_type_check;

create table if not exists nicheclubweb.brands (
  name     text primary key check (length(trim(name)) between 1 and 120),
  position integer not null default 0
);

-- slug: lo que va en la dirección, por ejemplo /fragancias#arabes
create table if not exists nicheclubweb.types (
  name     text primary key check (length(trim(name)) between 1 and 60),
  slug     text not null unique check (slug ~ '^[a-z0-9-]+$'),
  position integer not null default 0
);

-- Una sola fila con los datos de contacto y las fotos de portada
create table if not exists nicheclubweb.settings (
  id        integer primary key default 1 check (id = 1),
  whatsapp  text not null default '' check (whatsapp ~ '^[0-9]*$'),
  instagram text not null default '',
  email     text not null default '',
  hero1     text not null default '',
  hero2     text not null default '',
  hero3     text not null default '',
  cta_bg    text not null default ''
);

create table if not exists nicheclubweb.catalog_backups (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  data       jsonb not null
);
-- Las copias guardan también marcas y tipos, y por qué se hicieron
alter table nicheclubweb.catalog_backups add column if not exists brands jsonb;
alter table nicheclubweb.catalog_backups add column if not exists types  jsonb;
alter table nicheclubweb.catalog_backups add column if not exists reason text;

-- Usuarios con acceso al panel
create table if not exists nicheclubweb.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

-- 2. Permisos -------------------------------------------------------------

create or replace function nicheclubweb.is_admin()
returns boolean
language sql stable security definer set search_path = nicheclubweb
as $$
  select exists (select 1 from nicheclubweb.admins where user_id = auth.uid());
$$;

alter table nicheclubweb.products        enable row level security;
alter table nicheclubweb.brands          enable row level security;
alter table nicheclubweb.types           enable row level security;
alter table nicheclubweb.settings        enable row level security;
alter table nicheclubweb.catalog_backups enable row level security;
alter table nicheclubweb.admins          enable row level security;

drop policy if exists "products lectura" on nicheclubweb.products;
create policy "products lectura" on nicheclubweb.products
  for select to anon, authenticated using (visible or nicheclubweb.is_admin());

drop policy if exists "backups lectura admin" on nicheclubweb.catalog_backups;
create policy "backups lectura admin" on nicheclubweb.catalog_backups
  for select to authenticated using (nicheclubweb.is_admin());

-- Marcas, tipos y configuración: todos leen, solo el admin escribe
do $$
declare t text;
begin
  foreach t in array array['brands', 'types', 'settings'] loop
    execute format('drop policy if exists "%1$s lectura" on nicheclubweb.%1$I', t);
    execute format('create policy "%1$s lectura" on nicheclubweb.%1$I for select to anon, authenticated using (true)', t);
    execute format('drop policy if exists "%1$s admin" on nicheclubweb.%1$I', t);
    execute format('create policy "%1$s admin" on nicheclubweb.%1$I for all to authenticated using (nicheclubweb.is_admin()) with check (nicheclubweb.is_admin())', t);
  end loop;
end $$;

-- admins no tiene políticas: nadie la lee ni escribe desde la web.
-- Las escrituras del catálogo pasan solo por save_catalog().
revoke all on nicheclubweb.products, nicheclubweb.brands, nicheclubweb.types, nicheclubweb.settings,
  nicheclubweb.catalog_backups, nicheclubweb.admins from anon, authenticated;
grant select on nicheclubweb.products, nicheclubweb.brands, nicheclubweb.types, nicheclubweb.settings to anon, authenticated;
grant insert, update, delete on nicheclubweb.brands, nicheclubweb.types, nicheclubweb.settings to authenticated;
grant select on nicheclubweb.catalog_backups to authenticated;

-- 3. Guardar el catálogo completo (con copia de seguridad) -----------------

-- Copia de fragancias, marcas y tipos tal como están ahora (se guardan las últimas 30)
create or replace function nicheclubweb.take_snapshot(why text)
returns void
language sql security definer set search_path = nicheclubweb
as $$
  insert into nicheclubweb.catalog_backups (data, brands, types, reason)
  select coalesce((select jsonb_agg(to_jsonb(p) order by p.position) from nicheclubweb.products p), '[]'::jsonb),
         coalesce((select jsonb_agg(b.name order by b.name) from nicheclubweb.brands b), '[]'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'slug', t.slug, 'position', t.position) order by t.position) from nicheclubweb.types t), '[]'::jsonb),
         why;
  delete from nicheclubweb.catalog_backups
  where id not in (select id from nicheclubweb.catalog_backups order by created_at desc limit 30);
$$;
revoke all on function nicheclubweb.take_snapshot(text) from public, anon, authenticated;

-- Antes de eliminar o renombrar una marca o un tipo, se guarda una copia
create or replace function nicheclubweb.snapshot_trigger()
returns trigger
language plpgsql security definer set search_path = nicheclubweb
as $$
begin
  perform nicheclubweb.take_snapshot(tg_argv[0]);
  return null;
end;
$$;
drop trigger if exists brands_snapshot on nicheclubweb.brands;
create trigger brands_snapshot before delete or update of name on nicheclubweb.brands
  for each statement execute function nicheclubweb.snapshot_trigger('marcas');
drop trigger if exists types_snapshot on nicheclubweb.types;
create trigger types_snapshot before delete or update of name on nicheclubweb.types
  for each statement execute function nicheclubweb.snapshot_trigger('tipos');

create or replace function nicheclubweb.save_catalog(items jsonb)
returns setof nicheclubweb.products
language plpgsql security definer set search_path = nicheclubweb
as $$
begin
  if not nicheclubweb.is_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception 'El catálogo no puede quedar vacío.';
  end if;

  perform nicheclubweb.take_snapshot('catalogo');

  delete from nicheclubweb.products where true;
  insert into nicheclubweb.products (id, brand, name, type, img, p5, p10, status, visible, light, position)
  select v->>'id', trim(v->>'brand'), trim(v->>'name'), v->>'type', v->>'img',
         (v->>'p5')::integer, (v->>'p10')::integer, coalesce(v->>'status', 'Disponible'),
         coalesce((v->>'visible')::boolean, true), coalesce((v->>'light')::boolean, false), (ord - 1)::integer
  from jsonb_array_elements(items) with ordinality as e(v, ord);

  return query select * from nicheclubweb.products order by position;
end;
$$;

revoke all on function nicheclubweb.save_catalog(jsonb) from public, anon;
grant execute on function nicheclubweb.save_catalog(jsonb) to authenticated;
grant execute on function nicheclubweb.is_admin() to anon, authenticated;

-- 4. Fotos (productos y portada) --------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('nicheclub', 'nicheclub', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "nicheclub subir" on storage.objects;
create policy "nicheclub subir" on storage.objects
  for insert to authenticated with check (bucket_id = 'nicheclub' and nicheclubweb.is_admin());

drop policy if exists "nicheclub modificar" on storage.objects;
create policy "nicheclub modificar" on storage.objects
  for update to authenticated using (bucket_id = 'nicheclub' and nicheclubweb.is_admin());

drop policy if exists "nicheclub borrar" on storage.objects;
create policy "nicheclub borrar" on storage.objects
  for delete to authenticated using (bucket_id = 'nicheclub' and nicheclubweb.is_admin());

-- 5. Datos iniciales (solo si no existen) ------------------------------------

insert into nicheclubweb.types (name, slug, position) values
  ('Nicho', 'nicho', 0), ('Diseñador', 'disenador', 1), ('Árabe', 'arabes', 2)
on conflict do nothing;

insert into nicheclubweb.settings (id, whatsapp, instagram, email, hero1, hero2, hero3, cta_bg) values
  (1, '595994146975', 'nicheclub.py', '', 'img/productos/layton-exclusif.jpeg', 'img/bharara-king-portada.jpeg', 'img/productos/creed-aventus.jpeg', 'img/coleccion-fondo.jpeg')
on conflict do nothing;

insert into nicheclubweb.products (id, brand, name, type, img, p5, p10, status, visible, light, position)
select * from (values
  ('layton-exclusif', 'Parfums de Marly', 'Layton Exclusif', 'Nicho', 'img/productos/layton-exclusif.jpeg', 150000, 260000, 'Disponible', true, false, 0),
  ('creed-aventus', 'Creed', 'Aventus', 'Nicho', 'img/productos/creed-aventus.jpeg', 200000, 360000, 'Disponible', true, false, 1),
  ('lv-imagination', 'Louis Vuitton', 'Imagination', 'Nicho', 'img/productos/lv-imagination.jpeg', 215000, 399000, 'Disponible', true, false, 2),
  ('lv-limmensite', 'Louis Vuitton', 'L''Immensité', 'Nicho', 'img/productos/lv-limmensite.jpeg', 270000, 470000, 'Disponible', true, false, 3),
  ('tf-oud-wood', 'Tom Ford', 'Oud Wood', 'Nicho', 'img/productos/tf-oud-wood.jpeg', 180000, 290000, 'Disponible', true, false, 4),
  ('tf-costa-azzurra', 'Tom Ford', 'Costa Azzurra', 'Nicho', 'img/productos/tf-costa-azzurra.jpeg', 180000, 300000, 'Disponible', true, false, 5),
  ('sauvage-elixir', 'Dior', 'Sauvage Elixir', 'Diseñador', 'img/productos/sauvage-elixir.jpeg', 130000, 190000, 'Disponible', true, false, 6),
  ('ysl-y-edp', 'Yves Saint Laurent', 'Y Eau de Parfum', 'Diseñador', 'img/productos/ysl-y-edp.jpeg', 75000, 130000, 'Disponible', true, true, 7),
  ('swy-powerfully', 'Emporio Armani', 'Stronger With You Powerfully', 'Diseñador', 'img/productos/swy-powerfully.jpeg', 80000, 150000, 'Disponible', true, false, 8),
  ('power-of-you', 'Emporio Armani', 'Power of You', 'Diseñador', 'img/productos/power-of-you.jpeg', 90000, 130000, 'Disponible', true, true, 9),
  ('adg-profondo', 'Giorgio Armani', 'Acqua di Giò Profondo', 'Diseñador', 'img/productos/adg-profondo.jpeg', 60000, 110000, 'Disponible', true, true, 10),
  ('le-beau-le-parfum', 'Jean Paul Gaultier', 'Le Beau Le Parfum', 'Diseñador', 'img/productos/le-beau-le-parfum.jpeg', 60000, 115000, 'Disponible', true, true, 11),
  ('hawas-malibu', 'Rasasi', 'Hawas Malibu', 'Árabe', 'img/productos/hawas-malibu.jpeg', 35000, 50000, 'Disponible', true, true, 12),
  ('hawas-ice', 'Rasasi', 'Hawas Ice', 'Árabe', 'img/productos/hawas-ice.jpeg', 40000, 60000, 'Disponible', true, false, 13),
  ('supremacy-collectors', 'Afnan', 'Supremacy Collector''s Edition', 'Árabe', 'img/productos/supremacy-collectors.jpeg', 50000, 70000, 'Disponible', true, true, 14),
  ('afnan-9pm', 'Afnan', '9PM Rebel', 'Árabe', 'img/productos/afnan-9pm.jpeg', 35000, 50000, 'Disponible', true, false, 15),
  ('bharara-king', 'Bharara', 'King', 'Árabe', 'img/productos/bharara-king.jpeg', 50000, 70000, 'Disponible', true, false, 16),
  ('odyssey-aqua', 'Armaf', 'Odyssey Aqua Edition', 'Árabe', 'img/productos/odyssey-aqua.jpeg', 30000, 45000, 'Disponible', true, true, 17),
  ('philos-pura', 'Maison Alhambra', 'Philos Pura', 'Árabe', 'img/productos/philos-pura.jpeg', 35000, 50000, 'Disponible', true, true, 18)
) as v(id, brand, name, type, img, p5, p10, status, visible, light, position)
where not exists (select 1 from nicheclubweb.products);

-- Portadas 1 y 3 con las fotos de estudio, solo si siguen con las fotos anteriores
update nicheclubweb.settings set hero1 = 'img/productos/layton-exclusif.jpeg' where id = 1 and hero1 = 'img/layton-exclusif.jpeg';
update nicheclubweb.settings set hero3 = 'img/productos/creed-aventus.jpeg' where id = 1 and hero3 = 'img/creed-aventus.jpeg';

-- Fotos de estudio (octubre 2026): solo cambia las fragancias que todavía tienen la foto anterior
update nicheclubweb.products p set img = 'img/productos/' || p.id || '.jpeg'
where p.id in ('adg-profondo', 'afnan-9pm', 'bharara-king', 'creed-aventus', 'hawas-ice', 'hawas-malibu', 'layton-exclusif', 'le-beau-le-parfum', 'lv-imagination', 'lv-limmensite', 'odyssey-aqua', 'philos-pura', 'power-of-you', 'sauvage-elixir', 'supremacy-collectors', 'swy-powerfully', 'tf-costa-azzurra', 'tf-oud-wood', 'ysl-y-edp')
  and p.img not like 'img/productos/%' and p.img not like 'http%';

-- Marcas que ya se usan en el catálogo
insert into nicheclubweb.brands (name, position)
select brand, (row_number() over (order by brand))::integer - 1
from (select distinct brand from nicheclubweb.products) b
on conflict do nothing;

insert into nicheclubweb.types (name, slug, position)
select distinct p.type, regexp_replace(lower(p.type), '[^a-z0-9]+', '-', 'g'), 99
from nicheclubweb.products p
where not exists (select 1 from nicheclubweb.types t where t.name = p.type)
on conflict do nothing;

-- 6. Cada fragancia usa una marca y un tipo existentes ----------------------
-- Renombrar una marca o tipo actualiza las fragancias; no se puede borrar uno en uso.

alter table nicheclubweb.products drop constraint if exists products_brand_fkey;
alter table nicheclubweb.products add constraint products_brand_fkey
  foreign key (brand) references nicheclubweb.brands (name) on update cascade;

alter table nicheclubweb.products drop constraint if exists products_type_fkey;
alter table nicheclubweb.products add constraint products_type_fkey
  foreign key (type) references nicheclubweb.types (name) on update cascade;

-- 7. Que la API vea los cambios sin reiniciar -------------------------------

notify pgrst, 'reload schema';

-- 8. Dar acceso al panel ----------------------------------------------------
-- Requiere que el usuario ya exista en Authentication → Users.
-- Verificá ahí que la cuenta la creaste vos (el registro de este servidor está abierto).

insert into nicheclubweb.admins (user_id)
select id from auth.users where email = 'admin@nicheclubpy.com'
on conflict do nothing;

select case when exists (
  select 1 from nicheclubweb.admins a join auth.users u on u.id = a.user_id where u.email = 'admin@nicheclubpy.com'
) then 'Listo: admin@nicheclubpy.com tiene acceso al panel'
  else 'Falta crear el usuario admin@nicheclubpy.com en Authentication → Users y volver a correr este archivo'
end as resultado;
