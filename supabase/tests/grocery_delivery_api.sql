begin;
select plan(10);

select has_table('public', 'grocery_categories');
select has_table('public', 'grocery_items');
select has_table('public', 'inventory');
select has_table('public', 'delivery_riders');
select has_table('public', 'delivery_orders');
select has_view('public', 'grocery_catalog');
select has_function('public', 'check_item_availability', array['uuid', 'integer']);
select has_function('public', 'create_delivery_order', array['uuid', 'integer', 'text', 'text', 'text']);
select is((select count(*) from public.grocery_items), 12::bigint, 'contains 12 grocery products');
select is((select count(*) from public.delivery_riders), 5::bigint, 'contains 5 riders');

select * from finish();
rollback;
