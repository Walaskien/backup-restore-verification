-- No random() and no now(): the seed has to be identical on every start,
-- otherwise row checksums could not be compared between runs.
INSERT INTO customers (id, email, full_name, created_at)
SELECT g,
       'user' || g || '@example.test',
       'Customer ' || g,
       timestamptz '2026-01-01 00:00:00+00' + (g * interval '7 minutes')
FROM generate_series(1, 2000) AS g;

INSERT INTO orders (id, customer_id, amount_cents, status, placed_at)
SELECT g,
       1 + (g * 7919) % 2000,
       500 + (g * 37) % 25000,
       (ARRAY['new', 'paid', 'shipped', 'closed'])[1 + g % 4],
       timestamptz '2026-02-01 00:00:00+00' + (g * interval '90 seconds')
FROM generate_series(1, 20000) AS g;

INSERT INTO payments (id, order_id, method, paid_at)
SELECT g,
       g,
       (ARRAY['card', 'transfer', 'cash'])[1 + g % 3],
       timestamptz '2026-02-01 00:05:00+00' + (g * interval '90 seconds')
FROM generate_series(1, 20000) AS g;
