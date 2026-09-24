-- 0001_initial_schema.sql
-- Initial schema for the faceless YouTube production pipeline dashboard.
--
-- Tables:
--   channels              - the YouTube channels you run
--   videos                - one row per video, from raw idea through published
--   video_status_history  - audit log of every status change (filled by trigger)
--   video_daily_metrics   - one row per video per day of YouTube Analytics data
--
-- RLS is enabled on every table with no policies, so the anon/authenticated
-- roles can read and write nothing. The service role bypasses RLS.

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Keeps updated_at current on any table that has the column.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Pipeline stages
-- ---------------------------------------------------------------------------
-- Order matters: enum values sort in the order declared, so
-- "order by status" follows the pipeline. Add stages later with:
--   alter type public.video_status add value 'thumbnail' after 'editing';
create type public.video_status as enum (
  'idea',        -- in the backlog, not committed to yet
  'researching', -- gathering sources, facts and references
  'scripting',  -- script being written
  'voiceover',   -- narration being recorded / generated
  'editing',     -- visuals, B-roll, captions, thumbnail
  'ready',       -- finished, not yet uploaded
  'scheduled',   -- uploaded to YouTube, scheduled to go live
  'published',   -- live on YouTube
  'abandoned'    -- dropped at any stage; kept for reference
);

-- ---------------------------------------------------------------------------
-- channels
-- ---------------------------------------------------------------------------
create table public.channels (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null,
  youtube_channel_id text unique,          -- e.g. 'UCxxxxxxxxxxxxxxxxxxxxxx'; null until created
  handle             text unique,          -- e.g. '@mychannel'
  niche              text,
  description        text,
  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create trigger channels_set_updated_at
  before update on public.channels
  for each row execute function public.set_updated_at();

alter table public.channels enable row level security;

-- ---------------------------------------------------------------------------
-- videos
-- ---------------------------------------------------------------------------
-- A single table covers the whole lifecycle. An "idea" is just a video whose
-- status is 'idea'; a "published video" is one whose status is 'published'.
-- Fields that only apply to later stages are nullable, and check constraints
-- enforce what must be present at each stage.
create table public.videos (
  id                  uuid primary key default gen_random_uuid(),
  channel_id          uuid references public.channels (id) on delete restrict,
  status              public.video_status not null default 'idea',

  -- Idea stage
  title               text not null,       -- working title; update to the final title when publishing
  concept             text,                -- the pitch / angle / notes
  idea_source         text,                -- where it came from: competitor URL, comment, trend, etc.
  priority            smallint not null default 3 check (priority between 1 and 5),  -- 1 = highest

  -- Production stage
  script              text,
  target_publish_date date,

  -- Published stage
  youtube_video_id    text unique,         -- the 11-character ID, e.g. 'dQw4w9WgXcQ'
  youtube_url         text generated always as (
                        'https://www.youtube.com/watch?v=' || youtube_video_id
                      ) stored,
  published_at        timestamptz,
  duration_seconds    integer check (duration_seconds > 0),
  is_short            boolean not null default false,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  -- Ideas may float without a channel; anything actually in production needs one.
  constraint videos_channel_required_after_idea
    check (status in ('idea', 'abandoned') or channel_id is not null),

  -- A published video must have its YouTube ID and publish time.
  constraint videos_published_fields_required
    check (status <> 'published' or (youtube_video_id is not null and published_at is not null))
);

-- Postgres does not index foreign keys automatically; these back the common
-- "videos for this channel" and "everything in stage X" queries.
create index videos_channel_id_idx on public.videos (channel_id);
create index videos_status_idx on public.videos (status);

create trigger videos_set_updated_at
  before update on public.videos
  for each row execute function public.set_updated_at();

alter table public.videos enable row level security;

-- ---------------------------------------------------------------------------
-- video_status_history
-- ---------------------------------------------------------------------------
-- videos.status holds the current stage; this table records every change so
-- you can measure time spent in each stage and spot bottlenecks.
create table public.video_status_history (
  id          bigint generated always as identity primary key,
  video_id    uuid not null references public.videos (id) on delete cascade,
  from_status public.video_status,         -- null for the row logged on insert
  to_status   public.video_status not null,
  changed_at  timestamptz not null default now()
);

create index video_status_history_video_id_idx
  on public.video_status_history (video_id, changed_at);

alter table public.video_status_history enable row level security;

-- Logs the initial status on insert and every later status change.
create or replace function public.log_video_status_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.video_status_history (video_id, from_status, to_status)
    values (new.id, null, new.status);
  elsif new.status is distinct from old.status then
    insert into public.video_status_history (video_id, from_status, to_status)
    values (new.id, old.status, new.status);
  end if;
  return null;
end;
$$;

create trigger videos_log_status_change
  after insert or update of status on public.videos
  for each row execute function public.log_video_status_change();

-- ---------------------------------------------------------------------------
-- video_daily_metrics
-- ---------------------------------------------------------------------------
-- One row per video per day, holding that day's numbers (not running totals),
-- matching how the YouTube Analytics API reports with dimensions=day.
-- Lifetime totals are a SUM over the rows.
create table public.video_daily_metrics (
  id                        bigint generated always as identity primary key,
  video_id                  uuid not null references public.videos (id) on delete cascade,
  metric_date               date not null,

  views                     bigint not null default 0 check (views >= 0),
  watch_time_minutes        numeric(14, 2) not null default 0 check (watch_time_minutes >= 0),
  average_view_duration_sec numeric(10, 2) check (average_view_duration_sec >= 0),
  impressions               bigint check (impressions >= 0),
  ctr_percent               numeric(5, 2) check (ctr_percent between 0 and 100),  -- 4.75 means 4.75%
  subscribers_gained        integer not null default 0 check (subscribers_gained >= 0),
  subscribers_lost          integer not null default 0 check (subscribers_lost >= 0),

  fetched_at                timestamptz not null default now(),  -- when this row was last pulled from YouTube

  -- One row per video per day; re-syncing a day updates it via
  -- insert ... on conflict (video_id, metric_date) do update.
  -- The unique index also serves "metrics for this video" lookups.
  constraint video_daily_metrics_video_date_key unique (video_id, metric_date)
);

alter table public.video_daily_metrics enable row level security;
