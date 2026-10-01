-- Schema v1, migration 3 of 3: reporting views for Grafana.
-- All daily buckets use Europe/London dates. Energy views are deliberately absent until
-- the app's calorie anchor fix and resync are done (see the design page, build step 1).

-- Share of an interval sample that falls inside a window. Zero-length samples count whole.
-- Lives in reporting, not health, so a Grafana role with usage on reporting can run the views.
create function reporting.overlap_fraction(s_start timestamptz, s_end timestamptz, w_start timestamptz, w_end timestamptz)
returns double precision
language sql immutable set search_path = '' as $$
  select case
           when s_end <= s_start then 1.0
           else greatest(0.0, extract(epoch from least(s_end, w_end) - greatest(s_start, w_start))
                              / extract(epoch from s_end - s_start))
         end
$$;

-- Every numeric sample with its source, for ad hoc time series panels.
create view reporting.samples as
select x.type, x.start_at, x.end_at, x.value, s.name as source, s.kind as source_kind
from health.samples x
join health.sources s on s.id = x.source_id;

-- One row per workout. Distance and active energy come from the workout's own source,
-- falling back to Watch sources when that source wrote none. Samples straddling the
-- workout edges count pro rata. Heart rate is Watch only, inside the workout window.
create view reporting.workouts as
select w.uuid,
       w.activity,
       s.name as source,
       w.start_at,
       w.end_at,
       (w.start_at at time zone 'Europe/London')::date as local_date,
       w.duration_s,
       round((d.metres / 1000.0)::numeric, 3) as distance_km,
       case when w.activity = 'running' and d.metres > 0
            then round((w.duration_s / 60.0 / (d.metres / 1000.0))::numeric, 2) end as pace_min_per_km,
       hr.avg_bpm,
       hr.max_bpm,
       hr.samples as hr_samples,
       round(e.kcal::numeric, 1) as active_kcal
from health.workouts w
join health.sources s on s.id = w.source_id
cross join lateral (
  select coalesce(
    (select sum(x.value * reporting.overlap_fraction(x.start_at, x.end_at, w.start_at, w.end_at))
     from health.samples x
     where x.type = 'distance' and x.source_id = w.source_id
       and x.start_at < w.end_at and x.end_at > w.start_at),
    (select sum(x.value * reporting.overlap_fraction(x.start_at, x.end_at, w.start_at, w.end_at))
     from health.samples x join health.sources xs on xs.id = x.source_id
     where x.type = 'distance' and xs.kind = 'watch'
       and x.start_at < w.end_at and x.end_at > w.start_at)
  ) as metres
) d
cross join lateral (
  select coalesce(
    (select sum(x.value * reporting.overlap_fraction(x.start_at, x.end_at, w.start_at, w.end_at))
     from health.samples x
     where x.type = 'active_energy' and x.source_id = w.source_id
       and x.start_at < w.end_at and x.end_at > w.start_at),
    (select sum(x.value * reporting.overlap_fraction(x.start_at, x.end_at, w.start_at, w.end_at))
     from health.samples x join health.sources xs on xs.id = x.source_id
     where x.type = 'active_energy' and xs.kind = 'watch'
       and x.start_at < w.end_at and x.end_at > w.start_at)
  ) as kcal
) e
cross join lateral (
  select round(avg(x.value)::numeric, 1) as avg_bpm, max(x.value) as max_bpm, count(*) as samples
  from health.samples x join health.sources xs on xs.id = x.source_id
  where x.type = 'heart_rate' and xs.kind = 'watch'
    and x.start_at >= w.start_at and x.start_at <= w.end_at
) hr;

create view reporting.runs as
select * from reporting.workouts where activity = 'running';

-- Weeks start Monday (date_trunc on a London local date).
create view reporting.weekly_running as
select date_trunc('week', local_date)::date as week_start,
       count(*) as runs,
       round(sum(distance_km), 2) as distance_km,
       round(sum(duration_s) / 3600.0, 2) as hours,
       round((sum(duration_s) / 60.0 / nullif(sum(distance_km), 0))::numeric, 2) as avg_pace_min_per_km,
       round(sum(avg_bpm * hr_samples) / nullif(sum(hr_samples), 0), 1) as avg_bpm
from reporting.runs
group by 1;

-- Steps and walking or running distance per day. For each London hour the highest
-- priority source with any samples in that hour wins; the rest are ignored. This
-- approximates Health's own deduplication.
create view reporting.daily_activity as
with hourly as (
  select x.type,
         date_trunc('hour', x.start_at at time zone 'Europe/London') as local_hour,
         x.source_id,
         sum(x.value) as value
  from health.samples x
  where x.type in ('steps', 'distance')
  group by 1, 2, 3
),
ranked as (
  select h.*, row_number() over (partition by h.type, h.local_hour order by s.priority, h.value desc) as rn
  from hourly h join health.sources s on s.id = h.source_id
)
select local_hour::date as local_date,
       round(sum(value) filter (where type = 'steps')) as steps,
       round((sum(value) filter (where type = 'distance') / 1000.0)::numeric, 2) as distance_km
from ranked
where rn = 1
group by 1;

-- Last reading of the day for each body measure.
create view reporting.body_daily as
with r as (
  select x.type, (x.start_at at time zone 'Europe/London')::date as local_date, x.value,
         row_number() over (partition by x.type, (x.start_at at time zone 'Europe/London')::date order by x.start_at desc) as rn
  from health.samples x
  where x.type in ('weight', 'body_fat', 'lean_body_mass')
)
select local_date,
       round(max(value) filter (where type = 'weight')::numeric, 2) as weight_kg,
       round(max(value) filter (where type = 'body_fat')::numeric, 1) as body_fat_pct,
       round(max(value) filter (where type = 'lean_body_mass')::numeric, 2) as lean_mass_kg
from r
where rn = 1
group by 1;

create view reporting.vitals_daily as
select (x.start_at at time zone 'Europe/London')::date as local_date,
       round(avg(x.value) filter (where x.type = 'resting_heart_rate')::numeric, 1) as resting_bpm,
       round(avg(x.value) filter (where x.type = 'heart_rate_variability')::numeric, 1) as hrv_ms,
       round(avg(x.value) filter (where x.type = 'oxygen_saturation')::numeric, 1) as spo2_pct,
       round(avg(x.value) filter (where x.type = 'respiratory_rate')::numeric, 1) as respiratory_rate
from health.samples x
where x.type in ('resting_heart_rate', 'heart_rate_variability', 'oxygen_saturation', 'respiratory_rate')
group by 1;

-- A night runs from noon to noon (London) and is labelled with the wake date, so a stage
-- at 23:00 on the 19th and one at 05:00 on the 20th both belong to the night of the 20th.
-- Afternoon naps count towards the following night.
create view reporting.sleep_nightly as
select ((st.start_at at time zone 'Europe/London') + interval '12 hours')::date as wake_date,
       round(sum(extract(epoch from st.end_at - st.start_at)) filter (where st.stage in ('light', 'deep', 'rem', 'sleeping')) / 3600.0, 2) as asleep_h,
       round(sum(extract(epoch from st.end_at - st.start_at)) filter (where st.stage = 'deep') / 3600.0, 2) as deep_h,
       round(sum(extract(epoch from st.end_at - st.start_at)) filter (where st.stage = 'rem') / 3600.0, 2) as rem_h,
       round(sum(extract(epoch from st.end_at - st.start_at)) filter (where st.stage = 'light') / 3600.0, 2) as light_h,
       round(sum(extract(epoch from st.end_at - st.start_at)) filter (where st.stage = 'sleeping') / 3600.0, 2) as unstaged_h,
       round(sum(extract(epoch from st.end_at - st.start_at)) filter (where st.stage = 'awake') / 3600.0, 2) as awake_h,
       min(st.start_at) as bedtime,
       max(st.end_at) as wake_time
from health.sleep_stages st
group by 1;

revoke all on all tables in schema reporting from public, anon, authenticated;
