-- Replace the loose availability check with a short-lived quote that the client
-- must pass to create an order. Quotes lock price, not inventory.

create table public.order_quotes (
  id uuid primary key default gen_random_uuid(),
  grocery_item_id uuid not null references public.grocery_items(id),
  quantity integer not null check (quantity between 1 and 100),
  unit_price_cents integer not null check (unit_price_cents >= 0),
  total_cents integer not null check (total_cents >= 0),
  available_quantity integer not null check (available_quantity >= 0),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  check (expires_at > created_at),
  check (consumed_at is null or consumed_at >= created_at)
);

create index order_quotes_expires_at_idx on public.order_quotes (expires_at) where consumed_at is null;
create index order_quotes_grocery_item_id_idx on public.order_quotes (grocery_item_id);

alter table public.delivery_orders
  add column quote_id uuid references public.order_quotes(id);

alter table public.delivery_orders
  add constraint delivery_orders_quote_id_key unique (quote_id);

alter table public.order_quotes enable row level security;
revoke all on table public.order_quotes from anon, authenticated;

drop function if exists public.check_item_availability(uuid, integer);
drop function if exists public.create_delivery_order(uuid, integer, text, text, text);

create function public.create_order_quote(p_item_id uuid, p_quantity integer)
returns table (
  quote_id uuid,
  item_id uuid,
  item_name text,
  quantity integer,
  available_quantity integer,
  unit_price_cents integer,
  total_cents integer,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_item public.grocery_items%rowtype;
  selected_stock public.inventory%rowtype;
  new_quote public.order_quotes%rowtype;
begin
  if p_quantity is null or p_quantity <= 0 or p_quantity > 100 then
    raise exception 'quantity must be between 1 and 100' using errcode = '22023';
  end if;

  select item.* into selected_item
  from public.grocery_items as item
  where item.id = p_item_id and item.is_active = true;
  if not found then
    raise exception 'active grocery item not found' using errcode = 'P0002';
  end if;

  select stock.* into selected_stock
  from public.inventory as stock
  where stock.grocery_item_id = selected_item.id;
  if not found or selected_stock.quantity_available < p_quantity then
    raise exception 'insufficient inventory for requested quantity' using errcode = 'P0001';
  end if;

  insert into public.order_quotes (
    grocery_item_id,
    quantity,
    unit_price_cents,
    total_cents,
    available_quantity
  ) values (
    selected_item.id,
    p_quantity,
    selected_item.price_cents,
    selected_item.price_cents * p_quantity,
    selected_stock.quantity_available
  ) returning * into new_quote;

  return query
  select
    new_quote.id,
    selected_item.id,
    selected_item.name,
    new_quote.quantity,
    new_quote.available_quantity,
    new_quote.unit_price_cents,
    new_quote.total_cents,
    new_quote.expires_at;
end;
$$;

create function public.create_delivery_order(
  p_quote_id uuid,
  p_customer_name text,
  p_delivery_address text,
  p_customer_note text default null
)
returns table (
  order_id uuid,
  order_reference text,
  status public.delivery_order_status,
  quote_id uuid,
  item_id uuid,
  item_name text,
  quantity integer,
  total_cents integer,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_quote public.order_quotes%rowtype;
  selected_item public.grocery_items%rowtype;
  selected_stock public.inventory%rowtype;
  new_order public.delivery_orders%rowtype;
  normalized_name text := btrim(coalesce(p_customer_name, ''));
  normalized_address text := btrim(coalesce(p_delivery_address, ''));
  normalized_note text := nullif(btrim(coalesce(p_customer_note, '')), '');
begin
  if p_quote_id is null then
    raise exception 'quote id is required' using errcode = '22023';
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

  select quote.* into selected_quote
  from public.order_quotes as quote
  where quote.id = p_quote_id
  for update;
  if not found then
    raise exception 'quote not found' using errcode = 'P0002';
  end if;
  if selected_quote.consumed_at is not null then
    raise exception 'quote has already been used' using errcode = 'P0001';
  end if;
  if selected_quote.expires_at <= now() then
    raise exception 'quote has expired' using errcode = 'P0001';
  end if;

  select item.* into selected_item
  from public.grocery_items as item
  where item.id = selected_quote.grocery_item_id and item.is_active = true;
  if not found then
    raise exception 'quoted grocery item is no longer active' using errcode = 'P0002';
  end if;

  select stock.* into selected_stock
  from public.inventory as stock
  where stock.grocery_item_id = selected_quote.grocery_item_id
  for update;
  if not found or selected_stock.quantity_available < selected_quote.quantity then
    raise exception 'insufficient inventory for quoted quantity' using errcode = 'P0001';
  end if;

  update public.inventory
  set quantity_available = quantity_available - selected_quote.quantity
  where grocery_item_id = selected_quote.grocery_item_id;

  insert into public.delivery_orders (
    order_reference,
    quote_id,
    grocery_item_id,
    quantity,
    unit_price_cents,
    total_cents,
    customer_name,
    delivery_address,
    customer_note,
    status
  ) values (
    'GRO-' || to_char(now(), 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
    selected_quote.id,
    selected_item.id,
    selected_quote.quantity,
    selected_quote.unit_price_cents,
    selected_quote.total_cents,
    normalized_name,
    normalized_address,
    normalized_note,
    'pending_dispatch'
  ) returning * into new_order;

  update public.order_quotes
  set consumed_at = now()
  where id = selected_quote.id;

  return query
  select
    new_order.id,
    new_order.order_reference,
    new_order.status,
    selected_quote.id,
    selected_item.id,
    selected_item.name,
    new_order.quantity,
    new_order.total_cents,
    new_order.created_at;
end;
$$;

revoke all on function public.create_order_quote(uuid, integer) from public;
revoke all on function public.create_delivery_order(uuid, text, text, text) from public;
grant execute on function public.create_order_quote(uuid, integer) to anon, authenticated;
grant execute on function public.create_delivery_order(uuid, text, text, text) to anon, authenticated;
