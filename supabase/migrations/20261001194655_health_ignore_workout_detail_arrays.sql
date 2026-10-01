-- Workout detail (feat/workout-detail, merged 1 Oct 2026) adds two new payload
-- keys: workout_samples and workout_route. They are not single-value quantity
-- streams, so they do not fit health.sample_map. For now treat them like
-- 'exercise' and 'sleep': the processor skips them, raw rows stay in
-- public.health_payloads for a future schema v2 to replay.
--
-- Without this, process_payload raises "unmapped record arrays" on every
-- exercise page and the entire payload rolls back, leaving workouts and
-- their samples unnormalised.

create or replace function health.process_payload(p_id bigint) returns boolean
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
      and t.k not in ('exercise', 'sleep', 'workout_samples', 'workout_route')
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
revoke all on function health.process_payload(bigint) from public, anon, authenticated;
