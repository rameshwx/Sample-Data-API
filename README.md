# Grocery Delivery Sample API

A database-first Supabase sample API for a grocery delivery workflow. It has two independent reads, then two dependent calls: check inventory and create a pending-dispatch order.

## Included data

- 12 active grocery products across Fresh Produce, Dairy & Eggs, Bakery, and Pantry.
- One public Storage image URL alongside every grocery product.
- Inventory levels for every product.
- Five delivery riders and three historical/current delivery records.
- No Edge Functions and no user authentication; the public API uses your Supabase publishable key.

## API workflow

Set these only in your shell or deployment environment—never commit secrets:

```sh
export SUPABASE_URL='https://ntbnattqfhfqfdjrwmti.supabase.co'
export SUPABASE_PUBLISHABLE_KEY='your-publishable-key'
```

Every request uses these headers:

```sh
-H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
-H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY"
```

### 1. Independent — browse the catalog

```sh
curl "$SUPABASE_URL/rest/v1/grocery_catalog?select=id,sku,name,category_name,unit,price_cents,image_url&is_active=eq.true" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY"
```

Choose an `id` from this response. `image_url` is a public URL served from the `grocery-images` Storage bucket.

### 2. Independent — list riders

```sh
curl "$SUPABASE_URL/rest/v1/delivery_riders?select=id,display_name,vehicle_type,service_area,availability&availability=eq.available" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY"
```

This is an operational roster only. New orders deliberately remain `pending_dispatch`; dispatch assignment is not part of this four-call sample.

### 3. Dependent — check stock

Use the selected catalog item ID.

```sh
curl -X POST "$SUPABASE_URL/rest/v1/rpc/check_item_availability" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"p_item_id":"10000000-0000-0000-0000-000000000001","p_quantity":2}'
```

The response contains `available_quantity`, `total_cents`, and `is_available`. Quantities must be from 1 through 100.

### 4. Dependent — create the order

Call this only when the stock check returns `is_available: true`. The function locks inventory and checks it again before creating the order, so concurrent requests cannot oversell.

```sh
curl -X POST "$SUPABASE_URL/rest/v1/rpc/create_delivery_order" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "p_item_id":"10000000-0000-0000-0000-000000000001",
    "p_quantity":2,
    "p_customer_name":"Sam Taylor",
    "p_delivery_address":"42 Palm Grove, Colombo 3",
    "p_customer_note":"Please ring the bell"
  }'
```

The response includes an order reference, total, timestamp, and `pending_dispatch` status.

## Security model

Anonymous callers can read active catalog products and riders, and execute the two validation functions. They cannot read orders, inventory quantities, or write directly to any table. Storage objects are publicly downloadable, while writes require the service-role key used only by the GitHub Action.

## Deploying with the Supabase GitHub integration

1. In Supabase, set the GitHub integration working directory to `.` and enable deploy-to-production for `main`.
2. Add a required GitHub status check for the Supabase integration before merging to `main`.
3. Add these repository Actions secrets:
   - `SUPABASE_URL`: `https://ntbnattqfhfqfdjrwmti.supabase.co`
   - `SUPABASE_SERVICE_ROLE_KEY`: the project's service-role key (never a publishable key and never committed)
4. Push this repository. Supabase applies the migration and declares the public bucket. The `Sync grocery Storage images` workflow uploads the 12 versioned image files, creating the bucket idempotently if needed.

The database password shared earlier should be rotated before deployment. It is not used or stored by this repository.

## Local verification

Docker is required for the local Supabase stack.

```sh
supabase start
supabase db reset
supabase test db
```

Then run the four cURL calls above against the local API, substituting the local URL and anonymous key printed by `supabase status`. For a hosted smoke test, use the publishable key and verify that catalog image URLs return `200`, invalid quantities fail, insufficient stock fails, and direct anonymous inserts to `delivery_orders` or `inventory` are rejected.
