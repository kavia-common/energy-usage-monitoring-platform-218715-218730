# Energy Usage Monitoring Platform — PostgreSQL Schema (energy_db)

This container provides the PostgreSQL database schema for:
- Users (authentication/ownership)
- Devices
- Raw time-series readings
- Precomputed aggregates
- Alert rules (thresholds) + alert events
- Notification history (delivery/audit)

## Connection

The canonical connection string is stored in `db_connection.txt`.

Example:

```bash
psql postgresql://appuser:dbuser123@localhost:5000/myapp
```

## Extensions

- `pgcrypto` is enabled to support `gen_random_uuid()` for UUID primary keys.

## Tables

### `users`
Stores application users.

Columns:
- `id` (uuid, PK, default `gen_random_uuid()`)
- `email` (text, unique, not null)
- `password_hash` (text, not null) — backend-managed
- `full_name` (text, nullable)
- `is_active` (boolean, default true)
- `created_at`, `updated_at` (timestamptz)

Constraints:
- Unique `email`

### `devices`
Energy monitoring devices owned by a user.

Columns:
- `id` (uuid, PK)
- `user_id` (uuid, FK -> users.id, cascade on delete)
- `name` (text, not null)
- `location` (text)
- `type` (text, default `smart_plug`)
- `manufacturer`, `model`, `serial_number` (text)
- `is_active` (boolean, default true)
- `created_at`, `updated_at`

Constraints:
- Unique `(user_id, name)` (a user can't have two devices with same name)

Indexes:
- `idx_devices_user_id (user_id)`

### `readings`
Raw telemetry points (time-series).

Columns:
- `id` (bigserial, PK)
- `device_id` (uuid, FK -> devices.id, cascade on delete)
- `ts` (timestamptz, not null)
- `power_w` (numeric, not null, >= 0)
- `voltage_v` (numeric, >= 0)
- `current_a` (numeric, >= 0)
- `energy_wh` (numeric, >= 0)
- `cost` (numeric, >= 0)
- `raw` (jsonb) — optional original payload
- `created_at` (timestamptz)

Constraints:
- Unique `(device_id, ts)` to avoid duplicates for the same timestamp

Indexes:
- `idx_readings_device_ts (device_id, ts desc)` for "latest readings per device"
- `idx_readings_ts (ts desc)` for global time-window queries

### `aggregates`
Precomputed rollups/buckets for faster analytics.

Columns:
- `id` (bigserial, PK)
- `device_id` (uuid, FK -> devices.id, cascade on delete)
- `bucket_start` (timestamptz, not null)
- `bucket_end` (timestamptz, not null)
- `granularity` (text, not null, one of `hour|day|week|month`)
- `avg_power_w`, `min_power_w`, `max_power_w` (numeric, >= 0)
- `total_energy_wh` (numeric, >= 0)
- `total_cost` (numeric, >= 0)
- `created_at`

Constraints:
- Unique `(device_id, granularity, bucket_start)`

Indexes:
- `idx_aggregates_device_gran_bucket (device_id, granularity, bucket_start desc)`

### `alert_rules`
Threshold rules configured by users (optionally per device).

Columns:
- `id` (uuid, PK)
- `user_id` (uuid, FK -> users.id, cascade on delete)
- `device_id` (uuid, FK -> devices.id, cascade on delete, nullable for global/user-wide rule)
- `name` (text, not null)
- `metric` (text, not null, one of `power_w|energy_wh|cost`)
- `operator` (text, not null, one of `gt|gte|lt|lte|eq`)
- `threshold` (numeric, not null)
- `window_seconds` (int, default 0)
- `cooldown_seconds` (int, default 300)
- `is_enabled` (boolean, default true)
- `created_at`, `updated_at`

Constraints:
- Unique index `uq_alert_rules_user_device_name (user_id, device_id, name)` to avoid duplicates

Indexes:
- `idx_alert_rules_user_device_enabled (user_id, device_id, is_enabled)`

### `alert_events`
History of triggered alerts.

Columns:
- `id` (bigserial, PK)
- `rule_id` (uuid, FK -> alert_rules.id, cascade on delete)
- `device_id` (uuid, FK -> devices.id, set null on delete)
- `triggered_at` (timestamptz, default now())
- `metric_value` (numeric)
- `message` (text)
- `created_at` (timestamptz)

Indexes:
- `idx_alert_events_rule_triggered_at (rule_id, triggered_at desc)`

### `notification_history`
Delivery history/audit trail for notifications.

Columns:
- `id` (bigserial, PK)
- `event_id` (bigint, FK -> alert_events.id, set null on delete)
- `user_id` (uuid, FK -> users.id, cascade on delete)
- `channel` (text, one of `email|sms|push|webhook|in_app`)
- `destination` (text, nullable)
- `status` (text, one of `queued|sent|failed`)
- `sent_at` (timestamptz, nullable)
- `error` (text, nullable)
- `created_at` (timestamptz)

Indexes:
- `idx_notification_history_user_created_at (user_id, created_at desc)`

## Seed data (demo)

Inserted minimal demo records:
- User: `demo@energy.local` (password_hash placeholder `demo_hash`)
- Devices:
  - `Living Room Plug`
  - `Kitchen Plug`
- Readings:
  - Living Room: last ~3 hours, every 5 minutes
  - Kitchen: last ~4 hours, every 10 minutes
- Aggregates:
  - Hourly aggregates derived from readings (last ~6 hours)
- Alerts/notifications:
  - `High Power Alert` for Living Room
  - One `alert_event` + one `notification_history` entry

These seeds enable dashboards/analytics/alerts screens to have data immediately after DB startup.
