# Grocery Delivery Sample API

A database-first Supabase sample API for a grocery delivery workflow. It has two independent reads, then a strict quote-to-order dependency: the order request cannot be made without the `quote_id` returned by the quote request.

## Included data

- 12 active grocery products across Fresh Produce, Dairy & Eggs, Bakery, and Pantry.
- One public Storage image URL alongside every grocery product.
- Inventory levels and short-lived, price-locked order quotes.
- Five delivery riders and three historical/current delivery records.
- No Edge Functions and no user authentication; the public API uses your Supabase publishable key.

## API workflow

Set these only in your shell or deployment environment—never commit secrets:

```sh
export SUPABASE_URL='https://ntbnattqfhfqfdjrwmti.supabase.co'
export SUPABASE_PUBLISHABLE_KEY='your-publishable-key'
```

Every request uses this header:

```sh
-H "apikey: $SUPABASE_PUBLISHABLE_KEY"
```

### 1. Independent — browse the catalog

```sh
curl "$SUPABASE_URL/rest/v1/grocery_catalog?select=id,sku,name,category_name,unit,price_cents,image_url&is_active=eq.true" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY"
```

Choose an `id` from this response. The client sends that value as `p_item_id` when it creates an order quote. `image_url` is a public URL served from the `grocery-images` Storage bucket.

### 2. Independent — list riders

```sh
curl "$SUPABASE_URL/rest/v1/delivery_riders?select=id,display_name,vehicle_type,service_area,availability&availability=eq.available" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY"
```

This is an operational roster only. New orders deliberately remain `pending_dispatch`; dispatch assignment is not part of this four-call sample.

### 3. Dependent — create an order quote

Use the selected catalog item ID. This validates current stock, locks the item price for 10 minutes, and returns the `quote_id` required by the final call. A quote does not reserve stock.

```sh
curl -X POST "$SUPABASE_URL/rest/v1/rpc/create_order_quote" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"p_item_id":"10000000-0000-0000-0000-000000000001","p_quantity":2}'
```

The response contains `quote_id`, `available_quantity`, `unit_price_cents`, `total_cents`, and `expires_at`. Quantities must be from 1 through 100.

### 4. Dependent — confirm the order

Copy `quote_id` from Call 3 into `p_quote_id`. The function rejects unknown, expired, and previously consumed quotes. It locks and rechecks inventory before creating the order, so concurrent requests cannot oversell.

```sh
curl -X POST "$SUPABASE_URL/rest/v1/rpc/create_delivery_order" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "p_quote_id":"<quote_id from Call 3>",
    "p_customer_name":"Sam Taylor",
    "p_delivery_address":"42 Palm Grove, Colombo 3",
    "p_customer_note":"Please ring the bell"
  }'
```

The response includes the consumed quote ID, order reference, locked total, timestamp, and `pending_dispatch` status. Each quote can create one order only.

## Postman

Import [Grocery-Delivery-Sample-API.postman_collection.json](postman/Grocery-Delivery-Sample-API.postman_collection.json), then enter your publishable key in the collection's `publishableKey` variable. Run requests 1–3 in order; request 3 automatically saves `quote_id`, and request 4 uses it.

## Security model

Anonymous callers can read active catalog products and riders, and execute the quote and order-confirmation functions. They cannot read orders, quotes, or inventory quantities, and cannot write directly to any table. Storage objects are publicly downloadable, while writes require the service-role key used only by the GitHub Action.

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

Then run the four cURL calls above against the local API, substituting the local URL and anonymous key printed by `supabase status`. For a hosted smoke test, use the publishable key and verify that catalog image URLs return `200`, invalid quantities fail, quotes expire after 10 minutes, a quote can be confirmed only once, and direct anonymous inserts to `delivery_orders`, `order_quotes`, or `inventory` are rejected.
