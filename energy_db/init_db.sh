#!/bin/bash
set -euo pipefail

# Idempotent schema + seed initializer for the Energy Usage Monitoring Platform database.
#
# This script is designed to be safe to run repeatedly:
# - Uses IF NOT EXISTS where possible
# - Uses ON CONFLICT DO NOTHING for seed inserts
#
# It must be run AFTER PostgreSQL is up and the database/user exist.
#
# Connection variables are aligned with startup.sh defaults but can be overridden via env.
DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
DB_PORT="${DB_PORT:-5000}"
DB_HOST="${DB_HOST:-localhost}"

PG_VERSION="$(ls /usr/lib/postgresql/ | head -1)"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

PSQL_BASE=(sudo -u postgres "${PG_BIN}/psql" -v ON_ERROR_STOP=1 -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}")

echo "Applying schema + seed data to database '${DB_NAME}' on ${DB_HOST}:${DB_PORT}..."

# 1) Extensions
"${PSQL_BASE[@]}" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# 2) Tables
"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL UNIQUE,
  password_hash text NOT NULL,
  full_name text NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);"

"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name text NOT NULL,
  location text NULL,
  type text NOT NULL DEFAULT 'smart_plug',
  manufacturer text NULL,
  model text NULL,
  serial_number text NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_devices_user_name UNIQUE (user_id, name)
);"

"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS readings (
  id bigserial PRIMARY KEY,
  device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  ts timestamptz NOT NULL,
  power_w numeric NOT NULL CHECK (power_w >= 0),
  voltage_v numeric NULL CHECK (voltage_v >= 0),
  current_a numeric NULL CHECK (current_a >= 0),
  energy_wh numeric NULL CHECK (energy_wh >= 0),
  cost numeric NULL CHECK (cost >= 0),
  raw jsonb NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_readings_device_ts UNIQUE (device_id, ts)
);"

"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS aggregates (
  id bigserial PRIMARY KEY,
  device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  bucket_start timestamptz NOT NULL,
  bucket_end timestamptz NOT NULL,
  granularity text NOT NULL CHECK (granularity IN ('hour','day','week','month')),
  avg_power_w numeric NULL CHECK (avg_power_w >= 0),
  min_power_w numeric NULL CHECK (min_power_w >= 0),
  max_power_w numeric NULL CHECK (max_power_w >= 0),
  total_energy_wh numeric NULL CHECK (total_energy_wh >= 0),
  total_cost numeric NULL CHECK (total_cost >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_aggregates_device_gran_bucket UNIQUE (device_id, granularity, bucket_start)
);"

"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS alert_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id uuid NULL REFERENCES devices(id) ON DELETE CASCADE,
  name text NOT NULL,
  metric text NOT NULL CHECK (metric IN ('power_w','energy_wh','cost')),
  operator text NOT NULL CHECK (operator IN ('gt','gte','lt','lte','eq')),
  threshold numeric NOT NULL,
  window_seconds int NOT NULL DEFAULT 0 CHECK (window_seconds >= 0),
  cooldown_seconds int NOT NULL DEFAULT 300 CHECK (cooldown_seconds >= 0),
  is_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);"

# Partial uniqueness for (user_id, device_id, name) including NULL device_id:
# - normal UNIQUE won't treat NULLs as equal, so we enforce with two partial unique indexes.
"${PSQL_BASE[@]}" -c "
CREATE UNIQUE INDEX IF NOT EXISTS uq_alert_rules_user_device_name_notnull
  ON alert_rules(user_id, device_id, name)
  WHERE device_id IS NOT NULL;"
"${PSQL_BASE[@]}" -c "
CREATE UNIQUE INDEX IF NOT EXISTS uq_alert_rules_user_device_name_null
  ON alert_rules(user_id, name)
  WHERE device_id IS NULL;"

"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS alert_events (
  id bigserial PRIMARY KEY,
  rule_id uuid NOT NULL REFERENCES alert_rules(id) ON DELETE CASCADE,
  device_id uuid NULL REFERENCES devices(id) ON DELETE SET NULL,
  triggered_at timestamptz NOT NULL DEFAULT now(),
  metric_value numeric NULL,
  message text NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);"

"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS notification_history (
  id bigserial PRIMARY KEY,
  event_id bigint NULL REFERENCES alert_events(id) ON DELETE SET NULL,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel text NOT NULL CHECK (channel IN ('email','sms','push','webhook','in_app')),
  destination text NULL,
  status text NOT NULL CHECK (status IN ('queued','sent','failed')),
  sent_at timestamptz NULL,
  error text NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);"

# 3) Indexes
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_devices_user_id ON devices(user_id);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_readings_device_ts ON readings(device_id, ts DESC);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_readings_ts ON readings(ts DESC);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_aggregates_device_gran_bucket ON aggregates(device_id, granularity, bucket_start DESC);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_alert_rules_user_device_enabled ON alert_rules(user_id, device_id, is_enabled);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_alert_events_rule_triggered_at ON alert_events(rule_id, triggered_at DESC);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_notification_history_user_created_at ON notification_history(user_id, created_at DESC);"

# 4) Seed data (minimal, deterministic)
# Use fixed UUIDs so other components can reference stable IDs if needed.
DEMO_USER_ID="00000000-0000-0000-0000-000000000001"
LIVING_DEVICE_ID="00000000-0000-0000-0000-000000000101"
KITCHEN_DEVICE_ID="00000000-0000-0000-0000-000000000102"
DEMO_RULE_ID="00000000-0000-0000-0000-000000000201"

"${PSQL_BASE[@]}" -c "
INSERT INTO users (id, email, password_hash, full_name, is_active)
VALUES ('${DEMO_USER_ID}', 'demo@energy.local', 'demo_hash', 'Demo User', true)
ON CONFLICT (email) DO NOTHING;"

"${PSQL_BASE[@]}" -c "
INSERT INTO devices (id, user_id, name, location, type, manufacturer, model, serial_number, is_active)
VALUES
  ('${LIVING_DEVICE_ID}', '${DEMO_USER_ID}', 'Living Room Plug', 'Living Room', 'smart_plug', 'DemoCo', 'DP-1', 'LR-0001', true),
  ('${KITCHEN_DEVICE_ID}', '${DEMO_USER_ID}', 'Kitchen Plug', 'Kitchen', 'smart_plug', 'DemoCo', 'DP-1', 'KT-0001', true)
ON CONFLICT (id) DO NOTHING;"

# Insert a small amount of time-series data using generate_series (fast, minimal seed).
# Living Room: last ~3 hours, every 5 minutes (37 points).
"${PSQL_BASE[@]}" -c "
INSERT INTO readings (device_id, ts, power_w, voltage_v, current_a, energy_wh, cost, raw)
SELECT
  '${LIVING_DEVICE_ID}'::uuid,
  gs,
  ROUND( (80 + (random()*40))::numeric, 2 ) AS power_w,
  120::numeric AS voltage_v,
  ROUND( ((80 + (random()*40))/120)::numeric, 4 ) AS current_a,
  ROUND( ((80 + (random()*40)) * (5.0/60.0))::numeric, 2 ) AS energy_wh,
  ROUND( (((80 + (random()*40)) * (5.0/60.0)) * 0.0002)::numeric, 4 ) AS cost,
  jsonb_build_object('seed', true, 'interval_minutes', 5)
FROM generate_series(now() - interval '3 hours', now(), interval '5 minutes') gs
ON CONFLICT (device_id, ts) DO NOTHING;"

# Kitchen: last ~4 hours, every 10 minutes (25 points).
"${PSQL_BASE[@]}" -c "
INSERT INTO readings (device_id, ts, power_w, voltage_v, current_a, energy_wh, cost, raw)
SELECT
  '${KITCHEN_DEVICE_ID}'::uuid,
  gs,
  ROUND( (40 + (random()*30))::numeric, 2 ) AS power_w,
  120::numeric AS voltage_v,
  ROUND( ((40 + (random()*30))/120)::numeric, 4 ) AS current_a,
  ROUND( ((40 + (random()*30)) * (10.0/60.0))::numeric, 2 ) AS energy_wh,
  ROUND( (((40 + (random()*30)) * (10.0/60.0)) * 0.0002)::numeric, 4 ) AS cost,
  jsonb_build_object('seed', true, 'interval_minutes', 10)
FROM generate_series(now() - interval '4 hours', now(), interval '10 minutes') gs
ON CONFLICT (device_id, ts) DO NOTHING;"

# Hourly aggregates for last ~6 hours, derived from readings
"${PSQL_BASE[@]}" -c "
INSERT INTO aggregates (device_id, bucket_start, bucket_end, granularity, avg_power_w, min_power_w, max_power_w, total_energy_wh, total_cost)
SELECT
  r.device_id,
  date_trunc('hour', r.ts) AS bucket_start,
  date_trunc('hour', r.ts) + interval '1 hour' AS bucket_end,
  'hour' AS granularity,
  ROUND(avg(r.power_w)::numeric, 2) AS avg_power_w,
  ROUND(min(r.power_w)::numeric, 2) AS min_power_w,
  ROUND(max(r.power_w)::numeric, 2) AS max_power_w,
  ROUND(sum(COALESCE(r.energy_wh, 0))::numeric, 2) AS total_energy_wh,
  ROUND(sum(COALESCE(r.cost, 0))::numeric, 4) AS total_cost
FROM readings r
WHERE r.ts >= now() - interval '6 hours'
GROUP BY r.device_id, date_trunc('hour', r.ts)
ON CONFLICT (device_id, granularity, bucket_start) DO NOTHING;"

# Alert rule + one event + one notification
"${PSQL_BASE[@]}" -c "
INSERT INTO alert_rules (id, user_id, device_id, name, metric, operator, threshold, window_seconds, cooldown_seconds, is_enabled)
VALUES ('${DEMO_RULE_ID}', '${DEMO_USER_ID}', '${LIVING_DEVICE_ID}', 'High Power Alert', 'power_w', 'gt', 110, 0, 300, true)
ON CONFLICT DO NOTHING;"

"${PSQL_BASE[@]}" -c "
WITH ev AS (
  INSERT INTO alert_events (rule_id, device_id, triggered_at, metric_value, message)
  SELECT
    '${DEMO_RULE_ID}'::uuid,
    '${LIVING_DEVICE_ID}'::uuid,
    now(),
    120::numeric,
    'Seed demo: Living Room Plug exceeded 110W'
  WHERE NOT EXISTS (
    SELECT 1 FROM alert_events WHERE rule_id='${DEMO_RULE_ID}'::uuid
  )
  RETURNING id
)
INSERT INTO notification_history (event_id, user_id, channel, destination, status, sent_at, error)
SELECT
  ev.id,
  '${DEMO_USER_ID}'::uuid,
  'in_app',
  NULL,
  'sent',
  now(),
  NULL
FROM ev;"

echo "Schema + seed applied successfully."
