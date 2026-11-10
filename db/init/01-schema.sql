CREATE TABLE customers (
    id          integer PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    full_name   text NOT NULL,
    created_at  timestamptz NOT NULL
);

CREATE TABLE orders (
    id            bigint PRIMARY KEY,
    customer_id   integer NOT NULL REFERENCES customers (id),
    amount_cents  integer NOT NULL,
    status        text NOT NULL,
    placed_at     timestamptz NOT NULL
);

CREATE TABLE payments (
    id          bigint PRIMARY KEY,
    order_id    bigint NOT NULL REFERENCES orders (id),
    method      text NOT NULL,
    paid_at     timestamptz NOT NULL
);

CREATE INDEX orders_customer_idx ON orders (customer_id);
CREATE INDEX payments_order_idx ON payments (order_id);
