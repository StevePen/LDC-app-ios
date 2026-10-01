-- Device names contain a non-breaking space ("Apple Watch"), so match words, not spaces.
create or replace function health.classify_source(p_name text, out kind health.source_kind, out priority smallint)
language sql immutable set search_path = '' as $$
  select case
           when p_name ilike '%apple%watch%' then 'watch'::health.source_kind
           when p_name ilike '%phone%' then 'phone'::health.source_kind
         end,
         case
           when p_name ilike '%apple%watch%' then 1
           when p_name ilike '%phone%' then 3
           else 5
         end::smallint
$$;
revoke all on function health.classify_source(text) from public, anon, authenticated;

update health.sources
set kind = (health.classify_source(name)).kind,
    priority = (health.classify_source(name)).priority
where kind is null and (health.classify_source(name)).kind is not null;
