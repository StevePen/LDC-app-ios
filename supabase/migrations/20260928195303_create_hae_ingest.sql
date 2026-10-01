-- Raw Health Auto Export payloads, stored untouched so history can be replayed if the normalised schema changes
create table public.hae_payloads (
  id bigint generated always as identity primary key,
  received_at timestamptz not null default now(),
  headers jsonb,
  payload jsonb not null
);
create index hae_payloads_received_at_idx on public.hae_payloads (received_at desc);

-- Hashed ingest tokens; the plain token is only ever shown once
create table public.ingest_tokens (
  id bigint generated always as identity primary key,
  label text not null,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

-- Lock both down: no anon or authenticated access. The Edge Function uses the service role.
alter table public.hae_payloads enable row level security;
alter table public.ingest_tokens enable row level security;
revoke all on public.hae_payloads from anon, authenticated;
revoke all on public.ingest_tokens from anon, authenticated;
