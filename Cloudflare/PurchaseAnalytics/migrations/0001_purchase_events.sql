CREATE TABLE IF NOT EXISTS purchase_events (
    id TEXT PRIMARY KEY,
    received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    install_id_hash TEXT NOT NULL,
    session_id TEXT,
    event_name TEXT NOT NULL,
    paywall_source TEXT,
    purchase_result TEXT,
    product_load_result TEXT,
    product_load_state TEXT,
    storefront_country TEXT,
    app_version TEXT,
    build_number TEXT,
    platform TEXT,
    os_version TEXT,
    channel TEXT NOT NULL DEFAULT 'production'
);

CREATE INDEX IF NOT EXISTS idx_purchase_events_received_at ON purchase_events(received_at);
CREATE INDEX IF NOT EXISTS idx_purchase_events_event_name ON purchase_events(event_name);
CREATE INDEX IF NOT EXISTS idx_purchase_events_source ON purchase_events(paywall_source);
CREATE INDEX IF NOT EXISTS idx_purchase_events_channel ON purchase_events(channel);
