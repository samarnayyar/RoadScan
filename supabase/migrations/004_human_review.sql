-- ============================================================================
-- Migration 004 -- human-in-the-loop review for rejected photos
--
-- Run this in the Supabase SQL Editor AFTER 002. Safe to re-run.
--
-- Why
-- ---
-- The detector cannot tell three cases apart, because all three produce zero
-- detections:
--
--   1. a photo of something that is not a road at all  -> correctly rejected
--   2. a road with no damage on it                     -> correctly rejected
--   3. real damage the model failed to recognise       -> WRONGLY rejected
--
-- No confidence threshold separates (3) from (1) and (2); that is a property
-- of the model, not of the tuning. Measured on the trained YOLO11n, pothole
-- recall at the auto-accept point is 0.587, so roughly four in ten real
-- potholes are not detected outright. Without an escape hatch, every one of
-- those is a genuine report thrown away with the message "no pothole found".
--
-- This adds that escape hatch: the user asserts damage is present, the report
-- is filed but quarantined, and a human decides.
--
-- What "quarantined" means concretely
-- -----------------------------------
-- A pin under review is NOT trusted:
--   * it is created with review_state = 'pending'
--   * nearby_reports and all_reports exclude it, so it never appears on the
--     map or drives an alert until someone approves it
--   * it cannot be merged into by a later confident report, so one unreviewed
--     claim cannot silently inflate a real pin's confirmation count
--
-- That ordering matters. Filing straight to the map and reviewing afterwards
-- would mean the failure mode of this feature is "anyone can put anything on
-- the map by insisting", which is exactly the abuse the detector gate exists
-- to prevent.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. State
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'review_state') then
    create type review_state as enum ('auto', 'pending', 'approved', 'rejected');
  end if;
end
$$;

-- 'auto' is the default so every existing row, and every ordinary detected
-- report, keeps behaving exactly as before.
alter table hazard_reports
  add column if not exists review_state review_state not null default 'auto';

-- What the user claimed to see, in their words. Without it a reviewer is
-- looking at a photo the model found nothing in, with no idea what they are
-- supposed to be looking for.
alter table hazard_reports
  add column if not exists review_note text;

alter table hazard_reports
  add column if not exists reviewed_at timestamptz;

-- Partial index: the review queue is a small slice of a growing table, and
-- this keeps the admin query cheap without indexing the 'auto' majority.
create index if not exists hazard_reports_pending_review
  on hazard_reports (created_at)
  where review_state = 'pending';

-- ---------------------------------------------------------------------------
-- 2. Hide pending pins from every read path
--
-- Done by replacing the two read functions rather than by adding a filter at
-- each call site, so a future caller cannot forget it.
-- ---------------------------------------------------------------------------
create or replace function nearby_reports(
  p_lat      double precision,
  p_lon      double precision,
  p_radius_m double precision default 3000.0
)
returns table (
  id                 uuid,
  lat                double precision,
  lon                double precision,
  severity_score     double precision,
  severity           severity_class,
  hazard             hazard_class,
  confidence         double precision,
  confirmation_count integer,
  status             report_status,
  risk_level         text,
  created_at         timestamptz,
  last_confirmed_at  timestamptz,
  photo_count        integer,
  latest_photo       text,
  distance_m         double precision
)
language sql stable as $fn$
  select
    hr.id,
    st_y(hr.location::geometry),
    st_x(hr.location::geometry),
    hr.severity_score,
    hr.severity,
    hr.hazard,
    current_confidence(hr.base_confidence, hr.last_confirmed_at),
    hr.confirmation_count,
    derived_status(hr.status, hr.last_confirmed_at),
    hr.risk_level,
    hr.created_at,
    hr.last_confirmed_at,
    (select count(*)::integer from report_photos rp
      where rp.hazard_report_id = hr.id),
    (select rp.storage_path from report_photos rp
      where rp.hazard_report_id = hr.id
      order by rp.captured_at desc limit 1),
    st_distance(hr.location,
                st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography)
  from hazard_reports hr
  where hr.review_state <> 'pending'
    and st_dwithin(hr.location,
                   st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography,
                   p_radius_m)
  order by hr.location <-> st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography;
$fn$;

grant execute on function nearby_reports(double precision, double precision, double precision)
  to anon, authenticated;

create or replace function all_reports(p_limit integer default 200)
returns table (
  id                 uuid,
  lat                double precision,
  lon                double precision,
  severity_score     double precision,
  severity           severity_class,
  hazard             hazard_class,
  confidence         double precision,
  confirmation_count integer,
  status             report_status,
  risk_level         text,
  created_at         timestamptz,
  last_confirmed_at  timestamptz,
  photo_count        integer,
  latest_photo       text
)
language sql stable as $fn$
  select
    hr.id,
    st_y(hr.location::geometry),
    st_x(hr.location::geometry),
    hr.severity_score,
    hr.severity,
    hr.hazard,
    current_confidence(hr.base_confidence, hr.last_confirmed_at),
    hr.confirmation_count,
    derived_status(hr.status, hr.last_confirmed_at),
    hr.risk_level,
    hr.created_at,
    hr.last_confirmed_at,
    (select count(*)::integer from report_photos rp
      where rp.hazard_report_id = hr.id),
    (select rp.storage_path from report_photos rp
      where rp.hazard_report_id = hr.id
      order by rp.captured_at desc limit 1)
  from hazard_reports hr
  where hr.review_state <> 'pending'
  order by hr.last_confirmed_at desc
  limit p_limit;
$fn$;

grant execute on function all_reports to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. submit_report gains p_review_note
--
-- The old 9-argument signature is dropped first, for the same reason 002 had
-- to drop the 8-argument one: `create or replace` with a different argument
-- list creates an OVERLOAD rather than replacing, and then every unqualified
-- grant or drop on the name fails with "42725: function name is not unique"
-- -- while the old version stays callable and silently bypasses the new
-- behaviour.
-- ---------------------------------------------------------------------------
drop function if exists submit_report(
  double precision, double precision, double precision,
  severity_class, hazard_class, text, text, double precision, timestamptz
);

create or replace function submit_report(
  p_lat            double precision,
  p_lon            double precision,
  p_severity_score double precision,
  p_severity       severity_class,
  p_hazard         hazard_class,
  p_device_id      text,
  p_storage_path   text,
  p_radius_m       double precision default 20.0,
  p_captured_at    timestamptz default null,
  p_review_note    text default null
)
returns table (
  out_report_id     uuid,
  out_was_merged    boolean,
  out_confirmations integer
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_point    geography := st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography;
  v_existing hazard_reports%rowtype;
  v_observed timestamptz;
  v_review   review_state := case when p_review_note is null
                                  then 'auto'::review_state
                                  else 'pending'::review_state end;
begin
  v_observed := least(coalesce(p_captured_at, now()), now());

  -- A report awaiting review must not merge into a live pin. Merging would
  -- bump that pin's confirmation count and refresh its decay clock on the
  -- strength of a claim nobody has checked, which is precisely the influence
  -- the review gate is meant to withhold.
  if v_review = 'auto' then
    select * into v_existing
    from hazard_reports
    where status <> 'likely_fixed'
      and review_state <> 'pending'
      and hazard = p_hazard
      and st_dwithin(location, v_point, p_radius_m)
    order by location <-> v_point
    limit 1;
  end if;

  if found and v_review = 'auto' then
    insert into confirmations (hazard_report_id, device_id, was_negative)
    values (v_existing.id, p_device_id, false)
    on conflict (hazard_report_id, device_id, was_negative) do nothing;

    update hazard_reports
       set confirmation_count = (
             select greatest(count(distinct c.device_id), 1)
             from confirmations c
             where c.hazard_report_id = v_existing.id and not c.was_negative
           ),
           base_confidence    = 1.0,
           last_confirmed_at  = greatest(last_confirmed_at, v_observed),
           last_observed_at   = greatest(
                                  coalesce(last_observed_at, v_observed),
                                  v_observed),
           severity           = case when p_severity_score > severity_score
                                     then p_severity else severity end,
           severity_score     = greatest(severity_score, p_severity_score),
           status             = 'active'
     where id = v_existing.id;

    insert into report_photos
      (hazard_report_id, storage_path, is_original, severity_score, captured_at)
    values (v_existing.id, p_storage_path, false, p_severity_score, v_observed);

    return query
      select hr.id, true, hr.confirmation_count
      from hazard_reports hr where hr.id = v_existing.id;
  else
    insert into hazard_reports
      (location, severity_score, severity, hazard,
       created_at, last_confirmed_at, last_observed_at,
       review_state, review_note)
    values (v_point, p_severity_score, p_severity, p_hazard,
            v_observed, v_observed, v_observed,
            v_review, p_review_note)
    returning * into v_existing;

    insert into confirmations (hazard_report_id, device_id, was_negative)
    values (v_existing.id, p_device_id, false);

    insert into report_photos
      (hazard_report_id, storage_path, is_original, severity_score, captured_at)
    values (v_existing.id, p_storage_path, true, p_severity_score, v_observed);

    return query select v_existing.id, false, 1;
  end if;
end;
$fn$;

grant execute on function submit_report(
  double precision, double precision, double precision,
  severity_class, hazard_class, text, text, double precision, timestamptz, text
) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The review queue, for whoever is doing the reviewing.
--
-- Deliberately NOT granted to anon. Run it from the SQL Editor, or grant it
-- to an authenticated admin role once there is one. Exposing the queue to the
-- client would hand every user a list of unvetted photos.
-- ---------------------------------------------------------------------------
create or replace function review_queue(p_limit integer default 100)
returns table (
  id            uuid,
  lat           double precision,
  lon           double precision,
  hazard        hazard_class,
  review_note   text,
  created_at    timestamptz,
  photo_path    text
)
language sql stable as $fn$
  select
    hr.id,
    st_y(hr.location::geometry),
    st_x(hr.location::geometry),
    hr.hazard,
    hr.review_note,
    hr.created_at,
    (select rp.storage_path from report_photos rp
      where rp.hazard_report_id = hr.id
      order by rp.captured_at asc limit 1)
  from hazard_reports hr
  where hr.review_state = 'pending'
  order by hr.created_at asc
  limit p_limit;
$fn$;

-- Approve / reject, for the reviewer. Also not granted to anon.
create or replace function review_decide(p_report_id uuid, p_approve boolean)
returns void
language sql as $fn$
  update hazard_reports
     set review_state = case when p_approve then 'approved'::review_state
                             else 'rejected'::review_state end,
         reviewed_at  = now()
   where id = p_report_id;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Verify
-- ---------------------------------------------------------------------------
select count(*) filter (where review_state = 'pending') as pending,
       count(*) filter (where review_state = 'auto')    as auto,
       count(*)                                          as total
from hazard_reports;
