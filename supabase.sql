-- ============ BARBERÍA ENZO · esquema completo ============
-- Pegar entero en Supabase > SQL Editor > Run

create extension if not exists pgcrypto;

create table clientes (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  apellido text not null default '',
  telefono text not null unique,          -- solo dígitos
  activo boolean not null default true,   -- baja lógica
  created_at timestamptz not null default now()
);

create table servicios (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  precio numeric not null,
  activo boolean not null default true
);
insert into servicios (nombre, precio) values ('Corte', 17000), ('Corte y barba', 20000);

-- Plan mensual: 60.000 por mes, cortes semanales incluidos
create table planes (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id),
  mes date not null,                      -- primer día del mes (ej: 2026-11-01)
  precio numeric not null default 60000,
  pagado boolean not null default false,
  metodo_pago text check (metodo_pago in ('efectivo','transferencia')),
  fecha_pago date,
  unique (cliente_id, mes)
);

create table atenciones (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id),
  servicio_id uuid not null references servicios(id),
  fecha timestamptz not null,
  estado text not null default 'pendiente' check (estado in ('pendiente','listo','cancelado','pagado')),
  precio numeric not null,                -- precio congelado al agendar
  cubierto_por_plan boolean not null default false,
  metodo_pago text check (metodo_pago in ('efectivo','transferencia')),
  created_at timestamptz not null default now()
);
create index on atenciones (fecha);
create index on atenciones (cliente_id);

create table productos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  stock int not null default 0,
  stock_minimo int not null default 2,
  precio_venta numeric not null default 0,
  activo boolean not null default true
);

create table movimientos_stock (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos(id),
  tipo text not null check (tipo in ('entrada','venta','ajuste')),
  cantidad int not null,                  -- positiva; 'ajuste' puede ser negativa
  monto numeric not null default 0,       -- entrada: costo total · venta: total cobrado
  metodo_pago text check (metodo_pago in ('efectivo','transferencia')),
  fecha date not null default (now() at time zone 'America/Argentina/Cordoba')::date
);

create table movimientos_caja (
  id uuid primary key default gen_random_uuid(),
  fecha date not null default (now() at time zone 'America/Argentina/Cordoba')::date,
  tipo text not null check (tipo in ('ingreso','egreso')),
  categoria text not null,                -- corte, plan, producto, inversion, maquina, gasto, otro
  monto numeric not null check (monto >= 0),
  metodo_pago text not null check (metodo_pago in ('efectivo','transferencia')),
  descripcion text,
  atencion_id uuid references atenciones(id) on delete cascade,
  plan_id uuid references planes(id) on delete cascade,
  stock_id uuid references movimientos_stock(id) on delete cascade
);
create index on movimientos_caja (fecha);

create table cierres_caja (
  fecha date primary key,
  efectivo_esperado numeric not null,
  transferencia_esperada numeric not null,
  efectivo_contado numeric not null,
  diferencia numeric not null,
  notas text,
  created_at timestamptz not null default now()
);

-- Solicitudes del turnero público
create table solicitudes_turno (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id),
  servicio_id uuid references servicios(id),
  disponibilidad jsonb not null,          -- ["lun-tarde","mar-noche",...]
  notas text,
  estado text not null default 'pendiente' check (estado in ('pendiente','agendado','descartado')),
  atencion_id uuid references atenciones(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ============ TRIGGERS DE CAJA ============
-- Un corte solo suma a caja cuando está 'pagado' (y no está cubierto por plan)
create or replace function trg_atencion_caja() returns trigger language plpgsql as $$
begin
  delete from movimientos_caja where atencion_id = new.id;
  if new.estado = 'pagado' and not new.cubierto_por_plan and new.metodo_pago is not null then
    insert into movimientos_caja (fecha, tipo, categoria, monto, metodo_pago, descripcion, atencion_id)
    values ((now() at time zone 'America/Argentina/Cordoba')::date, 'ingreso', 'corte', new.precio, new.metodo_pago, 'Corte', new.id);
  end if;
  return new;
end $$;
create trigger atencion_caja after insert or update on atenciones
  for each row execute function trg_atencion_caja();

-- El plan suma a caja cuando se marca pagado
create or replace function trg_plan_caja() returns trigger language plpgsql as $$
begin
  delete from movimientos_caja where plan_id = new.id;
  if new.pagado and new.metodo_pago is not null then
    insert into movimientos_caja (fecha, tipo, categoria, monto, metodo_pago, descripcion, plan_id)
    values (coalesce(new.fecha_pago, (now() at time zone 'America/Argentina/Cordoba')::date), 'ingreso', 'plan', new.precio, new.metodo_pago, 'Plan mensual', new.id);
  end if;
  return new;
end $$;
create trigger plan_caja after insert or update on planes
  for each row execute function trg_plan_caja();

-- Stock: actualiza cantidad y registra venta (ingreso) o compra (egreso)
create or replace function trg_stock() returns trigger language plpgsql as $$
begin
  if new.tipo = 'entrada' then
    update productos set stock = stock + new.cantidad where id = new.producto_id;
    if new.monto > 0 and new.metodo_pago is not null then
      insert into movimientos_caja (fecha, tipo, categoria, monto, metodo_pago, descripcion, stock_id)
      values (new.fecha, 'egreso', 'compra_stock', new.monto, new.metodo_pago, 'Compra de producto', new.id);
    end if;
  elsif new.tipo = 'venta' then
    update productos set stock = stock - new.cantidad where id = new.producto_id;
    if new.metodo_pago is not null then
      insert into movimientos_caja (fecha, tipo, categoria, monto, metodo_pago, descripcion, stock_id)
      values (new.fecha, 'ingreso', 'producto', new.monto, new.metodo_pago, 'Venta de producto', new.id);
    end if;
  else
    update productos set stock = stock + new.cantidad where id = new.producto_id;
  end if;
  return new;
end $$;
create trigger stock_mov after insert on movimientos_stock
  for each row execute function trg_stock();

-- ============ SEGURIDAD (RLS) ============
-- Solo el email que cargues en "admins" puede leer y escribir. (Igual que es_socio en Royal Essence)
create table admins (email text primary key);
insert into admins values ('CAMBIAR-POR-EL-EMAIL-DE-ENZO@gmail.com');   -- <<< EDITAR ANTES DE EJECUTAR
alter table admins enable row level security;                            -- sin políticas: nadie la lee directo

create or replace function es_enzo() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from admins where lower(email) = lower(coalesce(auth.jwt()->>'email','')))
$$;
grant execute on function es_enzo to authenticated;

do $$
declare t text;
begin
  foreach t in array array['clientes','servicios','planes','atenciones','productos',
    'movimientos_stock','movimientos_caja','cierres_caja','solicitudes_turno']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "enzo_%1$s" on %1$I for all to authenticated using (es_enzo()) with check (es_enzo())', t);
  end loop;
end $$;

-- El público solo puede ver los servicios activos...
create policy "publico_servicios" on servicios for select to anon using (activo);

-- ...y crear solicitudes a través de esta función (no lee nada más)
create or replace function crear_solicitud(
  p_nombre text, p_apellido text, p_telefono text,
  p_servicio uuid, p_disponibilidad jsonb, p_notas text default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  tel text := regexp_replace(coalesce(p_telefono,''), '\D', '', 'g');
  v_cliente uuid;
begin
  if length(tel) < 8 or length(trim(coalesce(p_nombre,''))) < 2 then
    raise exception 'Datos inválidos';
  end if;
  if jsonb_array_length(p_disponibilidad) = 0 then
    raise exception 'Elegí al menos una franja';
  end if;
  select id into v_cliente from clientes where telefono = tel;
  if v_cliente is null then
    insert into clientes (nombre, apellido, telefono)
    values (trim(p_nombre), trim(coalesce(p_apellido,'')), tel) returning id into v_cliente;
  end if;
  -- anti-spam: máximo 2 solicitudes pendientes por cliente
  if (select count(*) from solicitudes_turno where cliente_id = v_cliente and estado = 'pendiente') >= 2 then
    raise exception 'Ya tenés solicitudes pendientes. Enzo te va a escribir.';
  end if;
  insert into solicitudes_turno (cliente_id, servicio_id, disponibilidad, notas)
  values (v_cliente, p_servicio, p_disponibilidad, left(p_notas, 300));
end $$;
revoke all on function crear_solicitud from public;
grant execute on function crear_solicitud to anon, authenticated;
