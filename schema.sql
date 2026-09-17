-- Mini Me-mao analytics schema (Neon Postgres, consumed via the Neon Data API / PostgREST).
--
-- Security model: the game POSTs rows directly to the Data API with NO Authorization header,
-- so Neon runs the request as the unauthenticated `anonymous` role. There is no API key to
-- ship — safety comes entirely from Row-Level Security: the `anonymous` role may only INSERT
-- into these tables (no SELECT/UPDATE/DELETE). Anyone who finds the public endpoint URL
-- can at worst append junk rows (rate-limit at the Neon/edge layer if that becomes a problem).
-- You read the data with your own authenticated connection (Neon SQL console).
--
-- Run this once in the Neon SQL editor. See README.md for the surrounding setup steps.

-- ── Tables ───────────────────────────────────────────────────────────────────

-- One row per play session, written on game exit.
create table if not exists public.sessions (
    id               uuid primary key default gen_random_uuid(),
    player_id        bigint      not null,          -- anonymous per-install id (g.player_id)
    session_id       uuid        not null,          -- unique per game launch
    started_at       timestamptz,
    ended_at         timestamptz,
    duration_seconds integer,
    gold             integer,                        -- final gold balance snapshot
    app_version      text,
    platform         text,
    raw_log          text,                           -- backup of this session's daily-log text
    created_at       timestamptz not null default now()
);

-- Structured, categorized gameplay events. `amount` is the gold delta:
-- negative = spent, positive = earned, null = non-economic event.
create table if not exists public.events (
    id          uuid primary key default gen_random_uuid(),
    player_id   bigint      not null,
    session_id  uuid        not null,               -- joins to sessions.session_id
    category    text        not null,               -- 'economy' | 'activity' | 'session'
    event       text        not null,               -- 'item_purchased', 'painting_sold', ...
    amount      integer,                             -- gold delta (nullable)
    data        jsonb       not null default '{}'::jsonb,
    occurred_at timestamptz,
    created_at  timestamptz not null default now()
);

-- Free-text feedback submitted from the in-game Feedback window.
create table if not exists public.feedback (
    id               uuid primary key default gen_random_uuid(),
    player_id        bigint      not null,
    session_id       uuid        not null,
    message          text        not null,
    playtime_seconds integer,
    app_version      text,
    created_at       timestamptz not null default now()
);

-- Survey answers from the in-game Feedback window's "Take Survey" flow. One row per question, so
-- the question set can change over time without a schema migration; group a submission by
-- (session_id, created_at). Answers may be blank if the player skipped a question.
create table if not exists public.survey_answers (
    id          uuid primary key default gen_random_uuid(),
    player_id   bigint      not null,
    session_id  uuid        not null,
    question    text        not null,
    answer      text,
    app_version text,
    created_at  timestamptz not null default now()
);

-- app_version on feedback/survey_answers was added after these tables first shipped — this backfills
-- an already-provisioned project the same way `create table if not exists` backfills a fresh one, so
-- re-running this file is safe either way.
alter table public.feedback       add column if not exists app_version text;
alter table public.survey_answers add column if not exists app_version text;

-- Helpful indexes for the queries you'll actually run (per-player, per-session, over time).
create index if not exists events_player_idx         on public.events (player_id);
create index if not exists events_session_idx        on public.events (session_id);
create index if not exists events_category_idx       on public.events (category, event);
create index if not exists sessions_player_idx       on public.sessions (player_id);
create index if not exists survey_answers_session_idx on public.survey_answers (session_id);

-- ── Row-Level Security: anonymous role may INSERT only ────────────────────────
-- NOTE: the Neon Data API's anonymous role is named `anonymous` by default. If your
-- project uses a different role name, change it in the four GRANT/POLICY blocks below.

alter table public.sessions       enable row level security;
alter table public.events         enable row level security;
alter table public.feedback       enable row level security;
alter table public.survey_answers enable row level security;

-- PostgREST needs the role to be able to "see" the schema before table grants apply.
grant usage on schema public to anonymous;

-- Insert-only grants (no select/update/delete for the anon role).
grant insert on public.sessions       to anonymous;
grant insert on public.events         to anonymous;
grant insert on public.feedback       to anonymous;
grant insert on public.survey_answers to anonymous;

drop policy if exists anon_insert_sessions on public.sessions;
create policy anon_insert_sessions on public.sessions
    for insert to anonymous with check (true);

drop policy if exists anon_insert_events on public.events;
create policy anon_insert_events on public.events
    for insert to anonymous with check (true);

drop policy if exists anon_insert_feedback on public.feedback;
create policy anon_insert_feedback on public.feedback
    for insert to anonymous with check (true);

drop policy if exists anon_insert_survey_answers on public.survey_answers;
create policy anon_insert_survey_answers on public.survey_answers
    for insert to anonymous with check (true);
