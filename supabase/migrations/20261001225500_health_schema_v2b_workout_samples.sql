-- Schema v2b: per-workout time-series samples (heart rate, running form, cycling, etc.)
-- parsed from the workout_samples payload array.

create type health.workout_sample_type as enum (
  'heart_rate',
  'active_energy',
  'basal_energy',
  'step_count',
  'flights_climbed',
  'distance_walking_running',
  'distance_cycling',
  'distance_swimming',
  'running_power',
  'running_speed',
  'running_stride_length',
  'running_vertical_oscillation',
  'running_ground_contact_time',
  'cycling_power',
  'cycling_speed',
  'cycling_cadence',
  'swimming_stroke_count'
);

create table health.workout_samples (
  uuid uuid primary key,
  workout_uuid uuid not null,
  type health.workout_sample_type not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  value double precision not null,
  unit text not null,
  source_id smallint references health.sources (id),
  payload_id bigint not null
);
create index workout_samples_wo_type_time_idx on health.workout_samples (workout_uuid, type, start_at);
comment on table health.workout_samples is 'Per-workout time-series samples parsed from the workout_samples payload array. Keyed on HK sample uuid so re-syncs dedupe. Overlaps with health.samples for shared types (heart_rate, distances, energies) by design.';

alter table health.workout_samples enable row level security;
revoke all on health.workout_samples from public, anon, authenticated;

-- Rewrite process_payload to also parse workout_samples.
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

    insert into health.workout_route_points (
      workout_uuid, timestamp, lat, lon,
      altitude_m, h_accuracy_m, v_accuracy_m,
      speed_mps, speed_accuracy_mps, course_deg, course_accuracy_deg,
      floor_level, route_uuid, payload_id
    )
    select (r ->> 'workout_uuid')::uuid,
           (r ->> 'timestamp')::timestamptz,
           (r ->> 'lat')::double precision,
           (r ->> 'lon')::double precision,
           (r ->> 'altitude_m')::double precision,
           (r ->> 'h_accuracy_m')::double precision,
           (r ->> 'v_accuracy_m')::double precision,
           (r ->> 'speed_mps')::double precision,
           (r ->> 'speed_accuracy_mps')::double precision,
           (r ->> 'course_deg')::double precision,
           (r ->> 'course_accuracy_deg')::double precision,
           nullif(r ->> 'floor_level', '')::smallint,
           (r ->> 'route_uuid')::uuid,
           p_id
    from jsonb_array_elements(case when jsonb_typeof(p -> 'workout_route') = 'array' then p -> 'workout_route' else '[]'::jsonb end) r
    on conflict (workout_uuid, timestamp) do nothing;

    insert into health.workout_samples (
      uuid, workout_uuid, type, start_at, end_at, value, unit, source_id, payload_id
    )
    select (r ->> 'uuid')::uuid,
           (r ->> 'workout_uuid')::uuid,
           (r ->> 'type')::health.workout_sample_type,
           (r ->> 'time')::timestamptz,
           coalesce((r ->> 'end_time')::timestamptz, (r ->> 'time')::timestamptz),
           (r ->> 'value')::double precision,
           r ->> 'unit',
           (select s.id from health.sources s where s.name = r ->> 'source'),
           p_id
    from jsonb_array_elements(case when jsonb_typeof(p -> 'workout_samples') = 'array' then p -> 'workout_samples' else '[]'::jsonb end) r
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

create view reporting.workout_samples as
select ws.workout_uuid,
       w.activity,
       s.name as workout_source,
       (w.start_at at time zone 'Europe/London')::date as local_date,
       ws.type::text as type,
       ws.start_at,
       ws.end_at,
       ws.value,
       ws.unit
from health.workout_samples ws
left join health.workouts w on w.uuid = ws.workout_uuid
left join health.sources s on s.id = w.source_id;

grant select on reporting.workout_samples to grafana_ro;
