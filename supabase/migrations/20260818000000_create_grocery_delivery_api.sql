-- Grocery delivery sample API. Demo rows live in the migration because production
-- GitHub deployments apply migrations but do not apply seed.sql.

create type public.rider_availability as enum ('available', 'on_delivery', 'offline');
create type public.delivery_order_status as enum ('pending_dispatch', 'dispatched', 'delivered', 'cancelled');

create table public.grocery_categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  name text not null unique,
  created_at timestamptz not null default now()
);

create table public.grocery_items (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.grocery_categories(id),
  sku text not null unique check (sku ~ '^[A-Z0-9-]+$'),
  name text not null,
  description text not null,
  unit text not null,
  price_cents integer not null check (price_cents >= 0),
  image_path text not null unique,
  image_url text not null unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.inventory (
  grocery_item_id uuid primary key references public.grocery_items(id) on delete cascade,
  quantity_available integer not null check (quantity_available >= 0),
  reorder_level integer not null default 5 check (reorder_level >= 0),
  updated_at timestamptz not null default now()
);

create table public.delivery_riders (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  vehicle_type text not null check (vehicle_type in ('bicycle', 'motorbike', 'scooter', 'van')),
  service_area text not null,
  availability public.rider_availability not null default 'offline',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.delivery_orders (
  id uuid primary key default gen_random_uuid(),
  order_reference text not null unique,
  grocery_item_id uuid not null references public.grocery_items(id),
  rider_id uuid references public.delivery_riders(id),
  quantity integer not null check (quantity > 0),
  unit_price_cents integer not null check (unit_price_cents >= 0),
  total_cents integer not null check (total_cents >= 0),
  customer_name text not null,
  delivery_address text not null,
  customer_note text,
  status public.delivery_order_status not null default 'pending_dispatch',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  delivered_at timestamptz,
  check ((status = 'delivered') = (delivered_at is not null)),
  check ((status in ('dispatched', 'delivered')) = (rider_id is not null))
);

create index delivery_orders_status_created_at_idx on public.delivery_orders (status, created_at desc);
create index delivery_orders_grocery_item_id_idx on public.delivery_orders (grocery_item_id);
create index delivery_orders_rider_id_idx on public.delivery_orders (rider_id);

create function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger grocery_items_set_updated_at before update on public.grocery_items for each row execute function public.set_updated_at();
create trigger inventory_set_updated_at before update on public.inventory for each row execute function public.set_updated_at();
create trigger delivery_riders_set_updated_at before update on public.delivery_riders for each row execute function public.set_updated_at();
create trigger delivery_orders_set_updated_at before update on public.delivery_orders for each row execute function public.set_updated_at();

create view public.grocery_catalog with (security_invoker = true) as
select
  item.id, item.sku, item.name, item.description,
  category.slug as category_slug, category.name as category_name,
  item.unit, item.price_cents, item.image_url, item.is_active
from public.grocery_items as item
join public.grocery_categories as category on category.id = item.category_id;

alter table public.grocery_categories enable row level security;
alter table public.grocery_items enable row level security;
alter table public.inventory enable row level security;
alter table public.delivery_riders enable row level security;
alter table public.delivery_orders enable row level security;

create policy "catalog categories are publicly readable" on public.grocery_categories for select to anon, authenticated using (true);
create policy "active grocery items are publicly readable" on public.grocery_items for select to anon, authenticated using (is_active = true);
create policy "rider roster is publicly readable" on public.delivery_riders for select to anon, authenticated using (true);

revoke all on table public.grocery_categories, public.grocery_items, public.inventory, public.delivery_riders, public.delivery_orders from anon, authenticated;
grant select on table public.grocery_categories, public.grocery_items, public.delivery_riders to anon, authenticated;
grant select on table public.grocery_catalog to anon, authenticated;

create function public.check_item_availability(p_item_id uuid, p_quantity integer)
returns table (
  item_id uuid, item_name text, requested_quantity integer, available_quantity integer,
  unit_price_cents integer, total_cents integer, is_available boolean
)
language plpgsql security definer set search_path = '' as $$
begin
  if p_quantity is null or p_quantity <= 0 or p_quantity > 100 then
    raise exception 'quantity must be between 1 and 100' using errcode = '22023';
  end if;

  return query
  select item.id, item.name, p_quantity, stock.quantity_available,
         item.price_cents, item.price_cents * p_quantity,
         stock.quantity_available >= p_quantity
  from public.grocery_items as item
  join public.inventory as stock on stock.grocery_item_id = item.id
  where item.id = p_item_id and item.is_active = true;

  if not found then
    raise exception 'active grocery item not found' using errcode = 'P0002';
  end if;
end;
$$;

create function public.create_delivery_order(
  p_item_id uuid,
  p_quantity integer,
  p_customer_name text,
  p_delivery_address text,
  p_customer_note text default null
)
returns table (
  order_id uuid, order_reference text, status public.delivery_order_status,
  item_id uuid, item_name text, quantity integer, total_cents integer, created_at timestamptz
)
language plpgsql security definer set search_path = '' as $$
declare
  selected_item public.grocery_items%rowtype;
  selected_stock public.inventory%rowtype;
  new_order public.delivery_orders%rowtype;
  normalized_name text := btrim(coalesce(p_customer_name, ''));
  normalized_address text := btrim(coalesce(p_delivery_address, ''));
  normalized_note text := nullif(btrim(coalesce(p_customer_note, '')), '');
begin
  if p_quantity is null or p_quantity <= 0 or p_quantity > 100 then
    raise exception 'quantity must be between 1 and 100' using errcode = '22023';
  end if;
  if char_length(normalized_name) not between 2 and 100 then
    raise exception 'customer name must contain 2 to 100 characters' using errcode = '22023';
  end if;
  if char_length(normalized_address) not between 8 and 300 then
    raise exception 'delivery address must contain 8 to 300 characters' using errcode = '22023';
  end if;
  if normalized_note is not null and char_length(normalized_note) > 300 then
    raise exception 'customer note must not exceed 300 characters' using errcode = '22023';
  end if;

  select item.* into selected_item
  from public.grocery_items as item
  where item.id = p_item_id and item.is_active = true;
  if not found then
    raise exception 'active grocery item not found' using errcode = 'P0002';
  end if;

  select stock.* into selected_stock
  from public.inventory as stock
  where stock.grocery_item_id = p_item_id
  for update;
  if selected_stock.quantity_available < p_quantity then
    raise exception 'insufficient inventory for requested quantity' using errcode = 'P0001';
  end if;

  update public.inventory
  set quantity_available = quantity_available - p_quantity
  where grocery_item_id = p_item_id;

  insert into public.delivery_orders (
    order_reference, grocery_item_id, quantity, unit_price_cents, total_cents,
    customer_name, delivery_address, customer_note, status
  ) values (
    'GRO-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
    selected_item.id, p_quantity, selected_item.price_cents, selected_item.price_cents * p_quantity,
    normalized_name, normalized_address, normalized_note, 'pending_dispatch'
  ) returning * into new_order;

  return query select new_order.id, new_order.order_reference, new_order.status,
    selected_item.id, selected_item.name, new_order.quantity, new_order.total_cents, new_order.created_at;
end;
$$;

revoke all on function public.check_item_availability(uuid, integer) from public;
revoke all on function public.create_delivery_order(uuid, integer, text, text, text) from public;
grant execute on function public.check_item_availability(uuid, integer) to anon, authenticated;
grant execute on function public.create_delivery_order(uuid, integer, text, text, text) to anon, authenticated;

insert into public.grocery_categories (id, slug, name) values
  ('00000000-0000-0000-0000-000000000001', 'fresh-produce', 'Fresh Produce'),
  ('00000000-0000-0000-0000-000000000002', 'dairy-eggs', 'Dairy & Eggs'),
  ('00000000-0000-0000-0000-000000000003', 'bakery', 'Bakery'),
  ('00000000-0000-0000-0000-000000000004', 'pantry', 'Pantry');

insert into public.grocery_items (id, category_id, sku, name, description, unit, price_cents, image_path, image_url) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'PRO-APPLE-001', 'Royal Gala Apples', 'Crisp, sweet apples selected for everyday snacking.', '1 kg bag', 690, 'royal-gala-apples.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/royal-gala-apples.png'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'PRO-BANANA-001', 'Cavendish Bananas', 'Naturally sweet ripe bananas in a family bunch.', '1 kg', 420, 'cavendish-bananas.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/cavendish-bananas.png'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001', 'PRO-AVOCADO-001', 'Hass Avocados', 'Creamy ready-to-ripen avocados.', 'pack of 2', 850, 'hass-avocados.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/hass-avocados.png'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', 'PRO-CARROT-001', 'Garden Carrots', 'Washed orange carrots with leafy freshness.', '500 g', 360, 'garden-carrots.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/garden-carrots.png'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000002', 'DAI-MILK-001', 'Fresh Whole Milk', 'Pasteurized whole milk for tea, cereal, and cooking.', '1 L', 580, 'fresh-whole-milk.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/fresh-whole-milk.png'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000002', 'DAI-YOGURT-001', 'Greek Yogurt', 'Thick plain Greek yogurt with a creamy finish.', '400 g', 790, 'greek-yogurt.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/greek-yogurt.png'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000002', 'DAI-EGGS-001', 'Free-range Eggs', 'Large free-range eggs from local farms.', 'pack of 12', 990, 'free-range-eggs.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/free-range-eggs.png'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-000000000003', 'BAK-BREAD-001', 'Sourdough Loaf', 'Slow-fermented crusty artisan sourdough.', '800 g loaf', 760, 'sourdough-loaf.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/sourdough-loaf.png'),
  ('10000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000003', 'BAK-CROISSANT-001', 'Butter Croissants', 'All-butter flaky croissants baked fresh.', 'pack of 4', 950, 'butter-croissants.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/butter-croissants.png'),
  ('10000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000004', 'PAN-RICE-001', 'Basmati Rice', 'Fragrant long-grain basmati rice.', '1 kg', 1150, 'basmati-rice.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/basmati-rice.png'),
  ('10000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000004', 'PAN-PASTA-001', 'Penne Pasta', 'Durum wheat penne pasta for quick dinners.', '500 g', 640, 'penne-pasta.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/penne-pasta.png'),
  ('10000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000004', 'PAN-COFFEE-001', 'Ground Coffee', 'Medium-roast Arabica ground coffee.', '250 g', 1380, 'ground-coffee.png', 'https://ntbnattqfhfqfdjrwmti.supabase.co/storage/v1/object/public/grocery-images/ground-coffee.png');

insert into public.inventory (grocery_item_id, quantity_available, reorder_level) values
  ('10000000-0000-0000-0000-000000000001', 42, 10), ('10000000-0000-0000-0000-000000000002', 55, 12),
  ('10000000-0000-0000-0000-000000000003', 18, 6), ('10000000-0000-0000-0000-000000000004', 33, 8),
  ('10000000-0000-0000-0000-000000000005', 28, 8), ('10000000-0000-0000-0000-000000000006', 21, 6),
  ('10000000-0000-0000-0000-000000000007', 16, 6), ('10000000-0000-0000-0000-000000000008', 12, 4),
  ('10000000-0000-0000-0000-000000000009', 20, 6), ('10000000-0000-0000-0000-000000000010', 37, 10),
  ('10000000-0000-0000-0000-000000000011', 44, 10), ('10000000-0000-0000-0000-000000000012', 14, 5);

insert into public.delivery_riders (id, display_name, vehicle_type, service_area, availability) values
  ('20000000-0000-0000-0000-000000000001', 'Asha Perera', 'motorbike', 'Colombo Central', 'available'),
  ('20000000-0000-0000-0000-000000000002', 'Nimal Fernando', 'scooter', 'Colombo North', 'available'),
  ('20000000-0000-0000-0000-000000000003', 'Kavindi Silva', 'bicycle', 'Colombo South', 'on_delivery'),
  ('20000000-0000-0000-0000-000000000004', 'Ruwan Jayasuriya', 'motorbike', 'Colombo East', 'on_delivery'),
  ('20000000-0000-0000-0000-000000000005', 'Mala Wijesinghe', 'van', 'Colombo West', 'offline');

insert into public.delivery_orders (id, order_reference, grocery_item_id, rider_id, quantity, unit_price_cents, total_cents, customer_name, delivery_address, customer_note, status, created_at, delivered_at) values
  ('30000000-0000-0000-0000-000000000001', 'GRO-DEMO-001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 2, 690, 1380, 'Leela De Silva', '28 Flower Road, Colombo 7', 'Leave with reception', 'dispatched', now() - interval '25 minutes', null),
  ('30000000-0000-0000-0000-000000000002', 'GRO-DEMO-002', '10000000-0000-0000-0000-000000000008', '20000000-0000-0000-0000-000000000004', 1, 760, 760, 'Kamal Dias', '102 Park Lane, Colombo 5', null, 'dispatched', now() - interval '12 minutes', null),
  ('30000000-0000-0000-0000-000000000003', 'GRO-DEMO-003', '10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000001', 1, 990, 990, 'Nadeesha Peris', '8 Lake Drive, Colombo 3', null, 'delivered', now() - interval '3 hours', now() - interval '2 hours 20 minutes');
