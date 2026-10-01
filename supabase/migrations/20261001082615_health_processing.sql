-- Schema v1, migration 2 of 3: payload parser, replay, ingest trigger.

-- Kind and priority for a source name seen for the first time.
create function health.classify_source(p_name text, out kind health.source_kind, out priority smallint)
language sql immutable set search_path = '' as $$
  select case
           when p_name ilike '%apple watch%' then 'watch'::health.source_kind
           when p_name ilike '%phone%' then 'phone'::health.source_kind
         end,
         case
           when p_name ilike '%apple watch%' then 1
           when p_name ilike '%phone%' then 3
           else 5
         end::smallint
$$;

-- Parses one payload into health.*. Never raises: on any error the payload's
-- inserts are rolled back and the error is written to process_error.
-- Unknown record arrays are an error, so a newly enabled type is not lost silently.
create function health.process_payload(p_id bigint) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  p jsonb;
  v_unmapped text;
  v_err text;
begin
  select payload into p from public.health_payloads where id = p_id;
  if p is null then
    return false;
  end if;

  begin
    select string_agg(t.k, ', ' order by t.k) into v_unmapped
    from jsonb_each(p) t (k, v)
    where jsonb_typeof(t.v) = 'array'
      and t.k not in ('exercise', 'sleep')
      and t.k not in (select m.payload_key from health.sample_map m);
    if v_unmapped is not null then
      raise exception 'unmapped record arrays: %', v_unmapped;
    end if;

    with names as (
      select r ->> 'source' as name
      from jsonb_each(p) t (k, v), jsonb_array_elements(t.v) r
      where jsonb_typeof(t.v) = 'array' and t.k <> 'sleep'
      union
      select st ->> 'source'
      from jsonb_array_elements(case when jsonb_typeof(p -> 'sleep') = 'array' then p -> 'sleep' else '[]'::jsonb end) s,
           jsonb_array_elements(s -> 'stages') st
    )
    insert into health.sources (name, kind, priority)
    select n.name, c.kind, c.priority
    from names n, health.classify_source(n.name) c
    where n.name is not null
    on conflict (name) do nothing;

    -- A missing source or value fails the not null constraints, which is intended.
    insert into health.samples (type, uuid, source_id, start_at, end_at, value, payload_id)
    select m.type,
           (r ->> 'uuid')::uuid,
           (select s.id from health.sources s where s.name = r ->> 'source'),
           coalesce(r ->> 'start_time', r ->> 'time')::timestamptz,
           coalesce(r ->> 'end_time', r ->> 'time')::timestamptz,
           (r ->> m.value_field)::double precision,
           p_id
    from health.sample_map m,
         jsonb_array_elements(case when jsonb_typeof(p -> m.payload_key) = 'array' then p -> m.payload_key else '[]'::jsonb end) r
    on conflict (type, uuid) do nothing;

    insert into health.workouts (uuid, activity, source_id, start_at, end_at, duration_s, payload_id)
    select (r ->> 'uuid')::uuid,
           r ->> 'type',
           (select s.id from health.sources s where s.name = r ->> 'source'),
           (r ->> 'start_time')::timestamptz,
           (r ->> 'end_time')::timestamptz,
           round((r ->> 'duration_seconds')::numeric)::integer,
           p_id
    from jsonb_array_elements(case when jsonb_typeof(p -> 'exercise') = 'array' then p -> 'exercise' else '[]'::jsonb end) r
    on conflict (uuid) do nothing;

    insert into health.sleep_stages (uuid, session_end_at, stage, source_id, start_at, end_at, payload_id)
    select (st ->> 'uuid')::uuid,
           (s ->> 'session_end_time')::timestamptz,
           st ->> 'stage',
           (select src.id from health.sources src where src.name = st ->> 'source'),
           (st ->> 'start_time')::timestamptz,
           (st ->> 'end_time')::timestamptz,
           p_id
    from jsonb_array_elements(case when jsonb_typeof(p -> 'sleep') = 'array' then p -> 'sleep' else '[]'::jsonb end) s,
         jsonb_array_elements(s -> 'stages') st
    on conflict (uuid) do nothing;

    update public.health_payloads set processed_at = now(), process_error = null where id = p_id;
    return true;
  exception when others then
    get stacked diagnostics v_err = message_text;
    update public.health_payloads
    set processed_at = null, process_error = sqlstate || ': ' || v_err
    where id = p_id;
    return false;
  end;
end;
$$;
comment on function health.process_payload(bigint) is 'Parses one health_payloads row into health.*. Idempotent. Errors go to health_payloads.process_error.';

-- Replays a range of payload ids. Returns how many succeeded and failed.
create function health.reprocess(p_from bigint, p_to bigint, out processed integer, out failed integer)
language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  processed := 0;
  failed := 0;
  for r in select id from public.health_payloads where id between p_from and p_to order by id loop
    if health.process_payload(r.id) then
      processed := processed + 1;
    else
      failed := failed + 1;
    end if;
  end loop;
end;
$$;

-- Replays everything, committing per batch. Run with CALL outside a transaction block
-- (SQL editor or psql). Not security definer because procedures that commit cannot be.
create procedure health.reprocess_all(p_batch integer default 100)
language plpgsql set search_path = '' as $$
declare
  v_lo bigint;
  v_max bigint;
begin
  select min(id), max(id) into v_lo, v_max from public.health_payloads;
  while v_lo <= v_max loop
    perform health.reprocess(v_lo, v_lo + p_batch - 1);
    commit;
    v_lo := v_lo + p_batch;
  end loop;
end;
$$;

-- Ingest must never fail because of parsing, so the trigger swallows anything
-- process_payload itself could not record.
create function health.on_payload_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform health.process_payload(new.id);
  exception when others then
    raise warning 'health.process_payload(%) failed: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;

create trigger health_payloads_process
after insert on public.health_payloads
for each row execute function health.on_payload_insert();

revoke all on all functions in schema health from public, anon, authenticated;
revoke all on procedure health.reprocess_all(integer) from public, anon, authenticated;
