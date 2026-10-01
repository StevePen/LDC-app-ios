-- Schema v1, migration 1 of 3: schemas, types, tables, indexes, privileges.
-- Design: Notion > Fitness Hub > Schema v1: normalised health data (design).

create schema health;
create schema reporting;
comment on schema health is 'Normalised HealthKit data parsed from public.health_payloads. Not exposed through the Supabase API.';
comment on schema reporting is 'Read-only views for Grafana. Not exposed through the Supabase API.';

create type health.sample_type as enum (
  'heart_rate', 'resting_heart_rate', 'heart_rate_variability', 'oxygen_saturation',
  'respiratory_rate', 'distance', 'steps', 'active_energy', 'total_energy',
  'weight', 'body_fat', 'lean_body_mass', 'height'
);

create type health.source_kind as enum ('watch', 'phone', 'app', 'scale');

-- Priority: lower wins when sources overlap. 5 means not yet reviewed.
create table health.sources (
  id smallint generated always as identity primary key,
  name text not null unique,
  kind health.source_kind,
  priority smallint not null default 5,
  created_at timestamptz not null default now()
);
comment on table health.sources is 'One row per HealthKit source name. New names are added by process_payload; review rows where kind is null.';

-- Watch and phone names (with curly apostrophes) are classified by pattern on first sight.
insert into health.sources (name, kind, priority) values
  ('Blood Oxygen', 'watch', 1),
  ('Nike Run Club', 'app', 2),
  ('Peloton', 'app', 2),
  ('Fitness', 'app', 2),
  ('eufy Life', 'scale', 4);

-- Maps a payload array key to a sample type and the field holding its value.
-- Adding a numeric type is one insert here plus one enum value.
create table health.sample_map (
  payload_key text primary key,
  type health.sample_type not null unique,
  value_field text not null
);
insert into health.sample_map (payload_key, type, value_field) values
  ('heart_rate', 'heart_rate', 'bpm'),
  ('resting_heart_rate', 'resting_heart_rate', 'bpm'),
  ('heart_rate_variability', 'heart_rate_variability', 'heart_rate_variability_millis'),
  ('oxygen_saturation', 'oxygen_saturation', 'percentage'),
  ('respiratory_rate', 'respiratory_rate', 'rate'),
  ('distance', 'distance', 'meters'),
  ('steps', 'steps', 'count'),
  ('active_calories', 'active_energy', 'calories'),
  ('total_calories', 'total_energy', 'calories'),
  ('weight', 'weight', 'kilograms'),
  ('body_fat', 'body_fat', 'percentage'),
  ('lean_body_mass', 'lean_body_mass', 'kilograms'),
  ('height', 'height', 'meters');

-- Columns ordered widest first to avoid alignment padding.
-- Units: distance and height m, energy kcal, body_fat and oxygen_saturation percent,
-- weight and lean_body_mass kg, heart_rate_variability ms. Point readings have start_at = end_at.
-- payload_id has no foreign key so processed payloads can be deleted later for retention.
create table health.samples (
  start_at timestamptz not null,
  end_at timestamptz not null,
  value double precision not null,
  payload_id bigint not null,
  uuid uuid not null,
  type health.sample_type not null,
  source_id smallint not null references health.sources (id),
  primary key (type, uuid)
);
create index samples_type_start_source_idx on health.samples (type, start_at, source_id);

create table health.workouts (
  uuid uuid primary key,
  start_at timestamptz not null,
  end_at timestamptz not null,
  payload_id bigint not null,
  duration_s integer not null,
  source_id smallint not null references health.sources (id),
  activity text not null
);
create index workouts_start_idx on health.workouts (start_at);

create table health.sleep_stages (
  uuid uuid primary key,
  start_at timestamptz not null,
  end_at timestamptz not null,
  session_end_at timestamptz not null,
  payload_id bigint not null,
  source_id smallint not null references health.sources (id),
  stage text not null
);
create index sleep_stages_start_idx on health.sleep_stages (start_at);

alter table public.health_payloads
  add column processed_at timestamptz,
  add column process_error text;

-- Privileges: nothing for the API roles. RLS on as a second guard.
alter table health.sources enable row level security;
alter table health.sample_map enable row level security;
alter table health.samples enable row level security;
alter table health.workouts enable row level security;
alter table health.sleep_stages enable row level security;

revoke all on schema health, reporting from public, anon, authenticated;
revoke all on all tables in schema health from public, anon, authenticated;
alter default privileges in schema health revoke all on tables from public, anon, authenticated;
alter default privileges in schema health revoke all on functions from public, anon, authenticated;
alter default privileges in schema reporting revoke all on tables from public, anon, authenticated;
