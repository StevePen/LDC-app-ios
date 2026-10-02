-- Read-only role for Grafana: SELECT on the reporting schema only. The password
-- is generated here and stored in Supabase Vault as grafana_ro_password; retrieve
-- it via `select decrypted_secret from vault.decrypted_secrets where name = 'grafana_ro_password';`
-- Idempotent: skip the role create and password rotate if the role already exists.

do $$
declare
  pw text;
  secret_id uuid;
begin
  if not exists (select 1 from pg_roles where rolname = 'grafana_ro') then
    pw := encode(extensions.gen_random_bytes(24), 'hex');
    execute format('create role grafana_ro with login password %L', pw);
    select vault.create_secret(pw, 'grafana_ro_password') into secret_id;
    raise notice 'grafana_ro created, password stored in Vault (secret id %)', secret_id;
  else
    raise notice 'grafana_ro already exists; leaving password alone';
  end if;
end $$;

grant usage on schema reporting to grafana_ro;
grant select on all tables in schema reporting to grafana_ro;
grant execute on function reporting.overlap_fraction(timestamptz, timestamptz, timestamptz, timestamptz) to grafana_ro;
alter default privileges in schema reporting grant select on tables to grafana_ro;
