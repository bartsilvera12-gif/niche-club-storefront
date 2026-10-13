-- Niche Club — catálogo y panel de administración en Supabase
-- Correr una sola vez en el SQL Editor de Supabase Studio.
-- Antes: crear el usuario admin@nicheclubpy.com en Authentication → Users (ver paso 3 al final).
-- Todo vive en el schema nicheclubweb para no mezclarse con otros proyectos del servidor.
-- La API tiene que exponer ese schema: ver el paso 0.

-- 0. Schema ---------------------------------------------------------------
-- La API (PostgREST) solo publica los schemas listados en PGRST_DB_SCHEMAS.
-- En el .env del Supabase self-hosted, agregar nicheclubweb a la lista existente, por ejemplo:
--   PGRST_DB_SCHEMAS=public,storage,graphql_public,nicheclubweb
-- y reiniciar el contenedor rest (docker compose up -d rest).

create schema if not exists nicheclubweb;
grant usage on schema nicheclubweb to anon, authenticated, service_role;

-- 1. Tablas ---------------------------------------------------------------

create table if not exists nicheclubweb.products (
  id         text primary key check (id ~ '^[a-z0-9-]+$'),
  brand      text not null check (length(trim(brand)) between 1 and 120),
  name       text not null check (length(trim(name)) between 1 and 120),
  type       text not null check (type in ('Nicho', 'Diseñador', 'Árabe')),
  img        text not null check (length(img) between 1 and 500),
  p5         integer not null check (p5 > 0),
  p10        integer not null check (p10 > 0),
  status     text not null default 'Disponible' check (status in ('Disponible', 'Agotado', 'Por encargo')),
  visible    boolean not null default true,
  light      boolean not null default false,
  position   integer not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists nicheclubweb.catalog_backups (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  data       jsonb not null
);

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
alter table nicheclubweb.catalog_backups enable row level security;
alter table nicheclubweb.admins          enable row level security;

drop policy if exists "products lectura" on nicheclubweb.products;
create policy "products lectura" on nicheclubweb.products
  for select to anon, authenticated using (visible or nicheclubweb.is_admin());

drop policy if exists "backups lectura admin" on nicheclubweb.catalog_backups;
create policy "backups lectura admin" on nicheclubweb.catalog_backups
  for select to authenticated using (nicheclubweb.is_admin());

-- admins no tiene políticas: nadie la lee ni escribe desde la web.
-- Las escrituras del catálogo pasan solo por save_catalog().
revoke all on nicheclubweb.products, nicheclubweb.catalog_backups, nicheclubweb.admins from anon, authenticated;
grant select on nicheclubweb.products to anon, authenticated;
grant select on nicheclubweb.catalog_backups to authenticated;

-- 3. Guardar el catálogo completo (con copia de seguridad) -----------------

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

  insert into nicheclubweb.catalog_backups (data)
  select coalesce(jsonb_agg(to_jsonb(p) order by p.position), '[]'::jsonb) from nicheclubweb.products p;
  delete from nicheclubweb.catalog_backups
  where id not in (select id from nicheclubweb.catalog_backups order by created_at desc limit 20);

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

-- 4. Fotos ----------------------------------------------------------------

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

-- 5. Catálogo inicial (solo si la tabla está vacía) -------------------------

insert into nicheclubweb.products (id, brand, name, type, img, p5, p10, status, visible, light, position)
select * from (values
  ('layton-exclusif', 'Parfums de Marly', 'Layton Exclusif', 'Nicho', 'img/layton-exclusif.jpeg', 150000, 260000, 'Disponible', true, false, 0),
  ('creed-aventus', 'Creed', 'Aventus', 'Nicho', 'img/creed-aventus.jpeg', 200000, 360000, 'Disponible', true, false, 1),
  ('lv-imagination', 'Louis Vuitton', 'Imagination', 'Nicho', 'img/lv-imagination.jpeg', 215000, 399000, 'Disponible', true, false, 2),
  ('lv-limmensite', 'Louis Vuitton', 'L''Immensité', 'Nicho', 'img/lv-limmensite.jpeg', 270000, 470000, 'Disponible', true, false, 3),
  ('tf-oud-wood', 'Tom Ford', 'Oud Wood', 'Nicho', 'img/tf-oud-wood.jpeg', 180000, 290000, 'Disponible', true, false, 4),
  ('tf-costa-azzurra', 'Tom Ford', 'Costa Azzurra', 'Nicho', 'img/tf-costa-azzurra.jpeg', 180000, 300000, 'Disponible', true, false, 5),
  ('sauvage-elixir', 'Dior', 'Sauvage Elixir', 'Diseñador', 'img/sauvage-elixir.jpeg', 130000, 190000, 'Disponible', true, false, 6),
  ('ysl-y-edp', 'Yves Saint Laurent', 'Y Eau de Parfum', 'Diseñador', 'img/ysl-y-edp.jpeg', 75000, 130000, 'Disponible', true, true, 7),
  ('swy-powerfully', 'Emporio Armani', 'Stronger With You Powerfully', 'Diseñador', 'img/stronger-with-you-powerfully-v2.jpeg', 80000, 150000, 'Disponible', true, false, 8),
  ('power-of-you', 'Emporio Armani', 'Power of You', 'Diseñador', 'img/power-of-you.jpeg', 90000, 130000, 'Disponible', true, true, 9),
  ('adg-profondo', 'Giorgio Armani', 'Acqua di Giò Profondo', 'Diseñador', 'img/acqua-di-gio-profondo.jpeg', 60000, 110000, 'Disponible', true, true, 10),
  ('le-beau-le-parfum', 'Jean Paul Gaultier', 'Le Beau Le Parfum', 'Diseñador', 'img/le-beau-le-parfum.jpeg', 60000, 115000, 'Disponible', true, true, 11),
  ('hawas-malibu', 'Rasasi', 'Hawas Malibu', 'Árabe', 'img/hawas-malibu.jpeg', 35000, 50000, 'Disponible', true, true, 12),
  ('hawas-ice', 'Rasasi', 'Hawas Ice', 'Árabe', 'img/hawas-ice-v2.jpeg', 40000, 60000, 'Disponible', true, false, 13),
  ('supremacy-collectors', 'Afnan', 'Supremacy Collector''s Edition', 'Árabe', 'img/supremacy-collectors.jpeg', 50000, 70000, 'Disponible', true, true, 14),
  ('afnan-9pm', 'Afnan', '9PM Rebel', 'Árabe', 'img/afnan-9pm.jpeg', 35000, 50000, 'Disponible', true, false, 15),
  ('bharara-king', 'Bharara', 'King', 'Árabe', 'img/bharara-king-v2.jpeg', 50000, 70000, 'Disponible', true, false, 16),
  ('odyssey-aqua', 'Armaf', 'Odyssey Aqua Edition', 'Árabe', 'img/odyssey-aqua.jpeg', 30000, 45000, 'Disponible', true, true, 17),
  ('philos-pura', 'Maison Alhambra', 'Philos Pura', 'Árabe', 'img/philos-pura.jpeg', 35000, 50000, 'Disponible', true, true, 18)
) as v(id, brand, name, type, img, p5, p10, status, visible, light, position)
where not exists (select 1 from nicheclubweb.products);

-- Que la API (PostgREST) vea las tablas y funciones nuevas sin reiniciar
notify pgrst, 'reload schema';

-- 6. Dar acceso al panel ----------------------------------------------------
-- Requiere que el usuario ya exista en Authentication → Users.
-- Verificá ahí que la cuenta la creaste vos (el registro de este servidor está abierto).

insert into nicheclubweb.admins (user_id)
select id from auth.users where email = 'admin@nicheclubpy.com'
on conflict do nothing;

-- 7. Que la API vea las tablas y funciones nuevas sin reiniciar ---------------

notify pgrst, 'reload schema';

select case when exists (
  select 1 from nicheclubweb.admins a join auth.users u on u.id = a.user_id where u.email = 'admin@nicheclubpy.com'
) then 'Listo: admin@nicheclubpy.com tiene acceso al panel'
  else 'Falta crear el usuario admin@nicheclubpy.com en Authentication → Users y volver a correr este archivo'
end as resultado;
