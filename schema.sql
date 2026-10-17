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

-- Studio-admin triage votes on feedback rows, written by the ZZZERO Discord bot's `/mini feedback`
-- browser (never by the game). One row per (feedback, admin). "close" is the only stored vote; an
-- admin's default "Open" state is the absence of their row (choosing Open deletes it). `voter` is a
-- fixed name key rather than a Discord ID so votes stay readable here and survive a Discord account
-- change.
create table if not exists public.feedback_votes (
    feedback_id uuid        not null references public.feedback(id) on delete cascade,
    voter       text        not null check (voter in ('memao', 'bronsky', 'ross')),
    status      text        not null check (status in ('close')),
    updated_at  timestamptz not null default now(),
    primary key (feedback_id, voter)
);

-- One-time migration: votes were originally completed/interesting/meh. Moving to Open/Close wiped
-- those votes (deliberately not mapped) and swapped the check constraint. Guarded on the old
-- constraint so re-running this file never wipes Open/Close votes.
do $$
begin
    if exists (
        select 1 from pg_constraint
        where conname = 'feedback_votes_status_check'
          and pg_get_constraintdef(oid) like '%interesting%'
    ) then
        delete from public.feedback_votes;
        alter table public.feedback_votes drop constraint feedback_votes_status_check;
        alter table public.feedback_votes add constraint feedback_votes_status_check check (status in ('close'));
    end if;
end
$$;

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
alter table public.feedback_votes enable row level security;  -- bot-only; no anonymous grants

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

-- ── ZZZERO Discord bot access (role: zzzero_bot) ──────────────────────────────
-- The studio's ZZZERO bot connects with its own login role (created via SQL, not the console's
-- Roles page — see README step 6) to browse feedback and record admin votes: read-only on feedback, read/write on
-- feedback_votes, nothing else. RLS is enabled and the role doesn't own these tables, so it needs
-- explicit policies on top of the grants. Skipped entirely if the role hasn't been created yet, so
-- this file still runs cleanly on a fresh project.
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'zzzero_bot') then
        grant usage on schema public to zzzero_bot;
        grant select on public.feedback to zzzero_bot;
        grant select, insert, update, delete on public.feedback_votes to zzzero_bot;

        drop policy if exists zzzero_bot_read_feedback on public.feedback;
        create policy zzzero_bot_read_feedback on public.feedback
            for select to zzzero_bot using (true);

        drop policy if exists zzzero_bot_all_feedback_votes on public.feedback_votes;
        create policy zzzero_bot_all_feedback_votes on public.feedback_votes
            for all to zzzero_bot using (true) with check (true);
    end if;
end
$$;
