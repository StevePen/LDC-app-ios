alter table public.hae_payloads rename to health_payloads;
alter index public.hae_payloads_received_at_idx rename to health_payloads_received_at_idx;
alter table public.health_payloads rename constraint hae_payloads_pkey to health_payloads_pkey;
comment on table public.health_payloads is 'Raw JSON posts from the iPhone Health exporter (LDC fork). Replay source for normalised tables.';
comment on table public.ingest_tokens is 'SHA-256 hashes of ingest tokens. Plain tokens live in Supabase Vault, not here.';
