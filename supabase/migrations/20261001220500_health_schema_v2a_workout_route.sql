-- Schema v2a: GPS points per workout. workout_samples is a later migration.
-- Design: Notion > Fitness Hub > Workout detail: capture plan.

create table health.workout_route_points (
  workout_uuid uuid not null,
  timestamp timestamptz not null,
  lat double precision not null,
  lon double precision not null,
  altitude_m double precision,
  h_accuracy_m double precision,
  v_accuracy_m double precision,
  speed_mps double precision,
  speed_accuracy_mps double precision,
  course_deg double precision,
  course_accuracy_deg double precision,
  floor_level smallint,
  route_uuid uuid,
  payload_id bigint not null,
  primary key (workout_uuid, timestamp)
);
create index workout_route_points_timestamp_idx on health.workout_route_points (timestamp);
comment on table health.workout_route_points is 'GPS points per workout, parsed from the workout_route payload array. Each point is one CLLocation; keyed on (workout_uuid, timestamp) so re-syncs dedupe.';

alter table health.workout_route_points enable row level security;
revoke all on health.workout_route_points from public, anon, authenticated;

-- Rewrite process_payload to also parse workout_route. workout_samples stays
-- in the ignore list for now (future migration will add its own table).
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

create view reporting.workout_route_points as
select rp.workout_uuid,
       w.activity,
       s.name as workout_source,
       (w.start_at at time zone 'Europe/London')::date as local_date,
       rp.timestamp,
       rp.lat,
       rp.lon,
       rp.altitude_m,
       rp.speed_mps,
       rp.course_deg,
       rp.h_accuracy_m
from health.workout_route_points rp
left join health.workouts w on w.uuid = rp.workout_uuid
left join health.sources s on s.id = w.source_id;

grant select on reporting.workout_route_points to grafana_ro;
