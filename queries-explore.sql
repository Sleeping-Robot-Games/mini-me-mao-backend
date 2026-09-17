-- Mini Me-mao analytics — exploratory / diagnostic queries.
--
-- Companion to queries.sql (which holds the stable "reporting" queries). This file is for
-- figuring out what's actually IN the database, whether collection is working, and what the
-- data can and can't tell you. Run in the Neon SQL console on your own authenticated
-- connection — the game's `anonymous` role is INSERT-only and can't SELECT any of this.
--
-- ── The 2026-08-12 cutoff ────────────────────────────────────────────────────
-- Everything below reads from v_sessions / v_events / v_feedback / v_survey_answers, thin
-- views that hide rows older than the cutoff. Run PART 0 once; after that the cutoff lives in
-- exactly one place (analytics_cutoff()) and every query in this file respects it. Nothing is
-- deleted — the old rows are still there if you ever want them. See PART 9 if you decide you
-- really do want them gone.
--
-- The views filter on created_at (server-side insert time), NOT started_at / occurred_at /
-- ended_at. Those three come from the player's own system clock: a skewed or deliberately
-- wrong clock puts a row on the wrong side of the cutoff, and a handful of rows always land
-- in 1970 or 2038. created_at is written by Postgres and is always trustworthy.


-- ═══ PART 0 — Setup: run this once ═══════════════════════════════════════════

-- Change the date here to move the cutoff for every query in this file.
create or replace function analytics_cutoff() returns timestamptz
language sql immutable as $$ select timestamptz '2026-08-12 00:00:00+00' $$;

create or replace view v_sessions       as select * from sessions       where created_at >= analytics_cutoff();
create or replace view v_events         as select * from events         where created_at >= analytics_cutoff();
create or replace view v_feedback       as select * from feedback       where created_at >= analytics_cutoff();
create or replace view v_survey_answers as select * from survey_answers where created_at >= analytics_cutoff();

-- How much you're excluding. If `before_cutoff` is large and `after_cutoff` is tiny, you may
-- want to move the cutoff back rather than analyze a handful of rows.
select 'sessions' as tbl,
       count(*) filter (where created_at <  analytics_cutoff()) as before_cutoff,
       count(*) filter (where created_at >= analytics_cutoff()) as after_cutoff
from sessions
union all select 'events',         count(*) filter (where created_at <  analytics_cutoff()),
                                   count(*) filter (where created_at >= analytics_cutoff()) from events
union all select 'feedback',       count(*) filter (where created_at <  analytics_cutoff()),
                                   count(*) filter (where created_at >= analytics_cutoff()) from feedback
union all select 'survey_answers', count(*) filter (where created_at <  analytics_cutoff()),
                                   count(*) filter (where created_at >= analytics_cutoff()) from survey_answers
order by 1;


-- ═══ PART 1 — RECON: run these first and send me the output ══════════════════
-- These seven are the ones I actually need to give you good analysis. They're all small.

-- R1. Volume and time span per table. Tells me whether there's enough data to say anything,
-- and whether collection is still running (last_row should be recent).
select 'sessions' as tbl, count(*) as rows, count(distinct player_id) as players,
       min(created_at) as first_row, max(created_at) as last_row from v_sessions
union all select 'events',         count(*), count(distinct player_id), min(created_at), max(created_at) from v_events
union all select 'feedback',       count(*), count(distinct player_id), min(created_at), max(created_at) from v_feedback
union all select 'survey_answers', count(*), count(distinct player_id), min(created_at), max(created_at) from v_survey_answers
order by 1;

-- R2. The event taxonomy that actually exists, plus the JSON keys each event carries. This is
-- the important one — it tells me which of the 14 tracked events are firing in the wild, and
-- confirms the `data` shape matches what the code claims.
select
  e.category,
  e.event,
  count(*)                                                    as n,
  count(distinct e.player_id)                                 as players,
  count(*) filter (where e.amount is not null)                as rows_with_amount,
  array_agg(distinct keys.k) filter (where keys.k is not null) as data_keys,
  min(e.occurred_at)                                          as first_seen,
  max(e.occurred_at)                                          as last_seen
from v_events e
left join lateral jsonb_object_keys(e.data) as keys(k) on true
group by 1, 2
order by n desc;

-- R3. One real example payload per event type, so I can see the actual value formats
-- (are star_tier / xp / progress numbers or strings? what do deco names look like?).
select distinct on (event) event, amount, data, occurred_at
from v_events
order by event, occurred_at desc;

-- R4. Session-row coverage. sessions rows are only written on clean exit, and never on web
-- (analytics.gd skips the exit POST when g.is_web). Everything in `missing_session_row` is a
-- web player, a crash, an OS-killed process, or an exit POST that blew the 2s timeout. Any
-- query that joins events to sessions silently drops all of them, so I need to know the size.
select
  count(distinct e.session_id)                                       as sessions_with_events,
  count(distinct e.session_id) filter (where s.session_id is null)   as missing_session_row,
  round(100.0 * count(distinct e.session_id) filter (where s.session_id is null)
        / nullif(count(distinct e.session_id), 0), 1)                as pct_missing
from v_events e
left join v_sessions s using (session_id);

-- R5. Platform / version spread, and whether raw_log is arriving. raw_log is capped at the
-- last 20000 chars, so avg_log_chars near 20000 means logs are being truncated.
select platform, app_version,
       count(*)                                            as sessions,
       count(distinct player_id)                           as players,
       count(*) filter (where coalesce(raw_log, '') <> '') as with_raw_log,
       round(avg(length(raw_log)))                         as avg_log_chars,
       max(length(raw_log))                                as max_log_chars
from v_sessions
group by 1, 2
order by sessions desc;

-- R6. The raw_log vocabulary, normalized (quoted names -> "X", numbers -> N) so variants
-- collapse into templates. Shows me every kind of line the game writes, and — more useful —
-- which lines have NO matching event in R2, i.e. things happening that you aren't tracking.
select
  regexp_replace(regexp_replace(msg, '"[^"]*"', '"X"', 'g'), '\d+', 'N', 'g') as template,
  count(*) as occurrences,
  count(distinct session_id) as sessions
from (
  select s.session_id,
         regexp_replace(trim(line), '^\d{2}:\d{2}:\d{2} - ', '') as msg
  from v_sessions s,
       lateral regexp_split_to_table(coalesce(s.raw_log, ''), E'\r?\n') as line
  where trim(line) <> ''
) x
group by 1
order by occurrences desc;

-- R7. Clock sanity. occurred_at comes from the player's machine; this flags nonsense rows so
-- I know whether to trust any time-based analysis at all.
select
  count(*)                                                                as events,
  count(*) filter (where occurred_at is null)                            as null_time,
  count(*) filter (where occurred_at > created_at + interval '1 day')    as far_future,
  count(*) filter (where occurred_at < created_at - interval '1 day')    as far_past,
  round(percentile_cont(0.5) within group (
        order by extract(epoch from (created_at - occurred_at)))::numeric, 1) as median_lag_seconds
from v_events;


-- ═══ PART 2 — "Is feedback / survey actually reaching Neon?" ═════════════════
-- Run F1 first. It answers the question directly; F2/F3 tell you why if the answer is no.

-- F1. The direct answer. Ignores the cutoff on purpose — if these are zero for ALL time,
-- the pipe has never worked, which is a different problem from "nothing since the 12th".
select
  (select count(*) from feedback)                                            as feedback_all_time,
  (select count(*) from feedback where created_at >= analytics_cutoff())     as feedback_since_cutoff,
  (select max(created_at) from feedback)                                     as feedback_last_row,
  (select count(*) from survey_answers)                                      as survey_all_time,
  (select count(*) from survey_answers where created_at >= analytics_cutoff()) as survey_since_cutoff,
  (select max(created_at) from survey_answers)                               as survey_last_row,
  (select count(*) from events)                                              as events_all_time;

-- F2. Which of the four survey questions come back, and how many people drop out mid-survey.
-- Answers post one at a time as the player advances, so question 1 having more rows than
-- question 4 is normal abandonment — but question 1 having rows while 2-4 have none would
-- point at the advance flow, not at the network.
select question,
       count(*)                                          as answers_posted,
       count(*) filter (where coalesce(answer,'') <> '') as non_blank,
       count(distinct session_id)                        as sessions,
       max(created_at)                                   as last_seen
from v_survey_answers
group by 1
order by answers_posted desc;

-- F3. Do the sessions that submitted feedback/survey also have ordinary events? If a
-- session_id appears in survey_answers but has zero events, the survey path works and the
-- event path doesn't (or vice versa) — that isolates the failure to one code path instead of
-- the whole HTTP/auth layer.
select
  sa.session_id,
  count(distinct sa.id)                     as survey_rows,
  (select count(*) from v_feedback f where f.session_id = sa.session_id) as feedback_rows,
  (select count(*) from v_events  e where e.session_id = sa.session_id)  as event_rows,
  (select count(*) from v_sessions s where s.session_id = sa.session_id) as session_rows,
  min(sa.created_at)                        as first_submission
from v_survey_answers sa
group by 1
order by first_submission desc
limit 50;


-- ═══ PART 3 — Session shape and quality ══════════════════════════════════════

-- How many sessions do nothing? A session whose only event is session_start is a launch with
-- no gameplay — the single most important number for judging whether the opening minute works.
with s as (
  select session_id,
         count(*) filter (where event <> 'session_start') as real_events,
         min(occurred_at) as t0,
         max(occurred_at) as t1
  from v_events
  group by 1
)
select
  count(*)                                                                   as sessions_seen,
  count(*) filter (where real_events = 0)                                    as did_nothing,
  round(100.0 * count(*) filter (where real_events = 0) / nullif(count(*),0), 1) as pct_did_nothing,
  round(avg(real_events), 1)                                                 as avg_events,
  percentile_cont(0.5) within group (order by real_events)                   as median_events,
  percentile_cont(0.9) within group (order by real_events)                   as p90_events,
  round(avg(extract(epoch from (t1 - t0)) / 60.0)::numeric, 1)               as avg_active_minutes
from s;

-- Wall-clock duration vs. active span. duration_seconds is wall clock from launch to quit and
-- counts time the game sat backgrounded — this is a desktop toy, so the gap can be enormous.
-- active_minutes (first event to last event) is the honest engagement number.
select
  s.session_id,
  s.platform,
  round(s.duration_seconds / 60.0, 1)                                        as wallclock_minutes,
  round(extract(epoch from (max(e.occurred_at) - min(e.occurred_at))) / 60.0)::numeric as active_minutes,
  count(*) filter (where e.event <> 'session_start')                         as events
from v_sessions s
join v_events e using (session_id)
group by 1, 2, 3
order by wallclock_minutes desc
limit 50;

-- Sessions per player per day — is anyone playing more than once a day?
select started_at::date as day,
       count(*)                                                as sessions,
       count(distinct player_id)                               as players,
       round(count(*)::numeric / nullif(count(distinct player_id), 0), 2) as sessions_per_player
from v_sessions
group by 1
order by 1 desc;


-- ═══ PART 4 — What players actually do, in order ═════════════════════════════

-- The opening funnel: of everyone who launched, what share ever reaches each activity? This
-- is the single most informative query in the file for a game this young.
with players as (select count(distinct player_id) as total from v_events)
select e.event,
       count(distinct e.player_id)                                                   as players,
       round(100.0 * count(distinct e.player_id) / nullif((select total from players), 0), 1) as pct_of_all_players,
       count(*)                                                                      as total_fires
from v_events e
group by 1
order by players desc;

-- First six things a player does in a session. Reveals whether people find the easel, or wander
-- into the shop, or bounce off the interact menu.
with ordered as (
  select session_id, event,
         row_number() over (partition by session_id order by occurred_at, id) as seq
  from v_events
  where event <> 'session_start'
)
select seq, event, count(*) as n
from ordered
where seq <= 6
group by 1, 2
order by seq, n desc;

-- The last thing a player does before quitting. Overrepresented events here are candidates for
-- "this is where the session dies" — either a natural stopping point or a frustration point.
with last_ev as (
  select distinct on (session_id) session_id, event
  from v_events
  where event <> 'session_start'
  order by session_id, occurred_at desc, id desc
)
select event, count(*) as sessions_ending_here,
       round(100.0 * count(*) / nullif(sum(count(*)) over (), 0), 1) as pct
from last_ev
group by 1
order by 2 desc;

-- How deep into a session each activity first appears. Things with a high median are things
-- players take a long time to discover — or that the game gates behind a long grind.
select e.event,
       count(*) as n,
       round(percentile_cont(0.5) within group (
             order by extract(epoch from (e.occurred_at - s.started_at)) / 60.0)::numeric, 1) as median_min_in,
       round(percentile_cont(0.9) within group (
             order by extract(epoch from (e.occurred_at - s.started_at)) / 60.0)::numeric, 1) as p90_min_in
from v_events e
join v_sessions s using (session_id)
where s.started_at is not null
  and e.occurred_at between s.started_at and s.started_at + interval '12 hours'
group by 1
order by median_min_in;

-- Refusals — the character declining an action. High counts on one reason means a need meter
-- or gate is too aggressive. Also shown per session so you can see if it's a few stuck players
-- or a broad problem.
select data->>'reason' as reason,
       count(*)                       as refusals,
       count(distinct session_id)     as sessions,
       round(count(*)::numeric / nullif(count(distinct session_id), 0), 1) as per_session
from v_events
where event = 'action_refused'
group by 1
order by refusals desc;


-- ═══ PART 5 — The painting loop (the core economy) ═══════════════════════════

-- Loop health in one row: brushstrokes -> finished paintings -> sales.
with per_session as (
  select session_id,
    count(*) filter (where event = 'painted_session')   as strokes,
    count(*) filter (where event = 'painting_finished') as made,
    count(*) filter (where event = 'painting_sold')     as sold
  from v_events
  group by 1
)
select
  sum(strokes)                                                   as paint_sessions,
  sum(made)                                                      as paintings_finished,
  sum(sold)                                                      as paintings_sold,
  round(sum(strokes)::numeric / nullif(sum(made), 0), 1)         as strokes_per_painting,
  round(100.0 * sum(sold) / nullif(sum(made), 0), 1)             as pct_sell_through,
  count(*) filter (where made > 0)                               as sessions_finishing_a_painting,
  count(*) filter (where sold > 0)                               as sessions_selling_a_painting
from per_session;

-- Where paintings get abandoned. painted_session carries `progress` (0-1); if the distribution
-- piles up below 1.0 without a matching painting_finished, people are walking away mid-canvas.
select least(width_bucket((data->>'progress')::float, 0, 1, 10), 10) * 10 as progress_pct_bucket,
       count(*) as paint_sessions
from v_events
where event = 'painted_session' and data->>'progress' is not null
group by 1
order by 1;

-- Star tier economics — is the tier spread meaningful, or does everything sell for about the same?
select (data->>'star_tier')::int as star_tier,
       count(*)                                                  as sold,
       min(amount)                                               as min_gold,
       round(avg(amount))                                        as avg_gold,
       percentile_cont(0.5) within group (order by amount)       as median_gold,
       max(amount)                                               as max_gold,
       sum(amount)                                               as total_gold,
       round(100.0 * count(*) / nullif(sum(count(*)) over (), 0), 1) as pct_of_sales
from v_events
where event = 'painting_sold'
group by 1
order by 1;

-- Do people sell one at a time or dump the whole rack? sell_all fires one painting_sold per
-- painting within the same instant, so a burst of sales inside a second is a rack dump.
with bursts as (
  select session_id,
         date_trunc('second', occurred_at) as t,
         count(*) as sold_together,
         sum(amount) as gold
  from v_events
  where event = 'painting_sold'
  group by 1, 2
)
select sold_together, count(*) as times, round(avg(gold)) as avg_gold_per_burst
from bursts
group by 1
order by 1;

-- Painting categories people actually paint.
select data->>'category' as category,
       count(*) as finished,
       count(distinct player_id) as players,
       round(avg((data->>'xp')::float * 100)::numeric, 1) as avg_xp_pct
from v_events
where event = 'painting_finished'
group by 1
order by finished desc;


-- ═══ PART 6 — Gold: sources, sinks, and inflation ════════════════════════════

-- Every gold source and sink side by side. If sources dwarf sinks, gold is meaningless and the
-- shop has no pull; if sinks dwarf sources, players are stuck.
select case when amount > 0 then 'source' else 'sink' end as kind,
       event,
       count(*)                as fires,
       sum(abs(amount))        as gold,
       round(avg(abs(amount))) as avg_per_fire,
       round(100.0 * sum(abs(amount)) / sum(sum(abs(amount))) over (
             partition by case when amount > 0 then 'source' else 'sink' end), 1) as pct_of_side
from v_events
where category = 'economy' and amount is not null and amount <> 0
group by 1, 2
order by kind, gold desc;

-- Gold balance at exit, by how many sessions the player has under their belt. A line that only
-- goes up means there's nothing worth buying at the top end.
with idx as (
  select player_id, gold,
         row_number() over (partition by player_id order by started_at) as session_no
  from v_sessions
  where gold is not null
)
select session_no,
       count(*) as players,
       round(avg(gold))                                    as avg_gold_at_exit,
       percentile_cont(0.5) within group (order by gold)   as median_gold,
       max(gold)                                           as max_gold
from idx
group by 1
order by 1;

-- Spend conversion: what share of players ever buy anything, upgrade the rack, or reroll deals.
select count(distinct player_id)                                                  as players,
       count(distinct player_id) filter (where event = 'item_purchased')          as bought_an_item,
       count(distinct player_id) filter (where event = 'rack_upgrade_purchased')  as upgraded_rack,
       count(distinct player_id) filter (where event = 'daily_deal_reroll')       as rerolled_a_deal,
       round(100.0 * count(distinct player_id) filter (where event = 'item_purchased')
             / nullif(count(distinct player_id), 0), 1)                           as pct_bought
from v_events;

-- Purchases by source and category together — the version in queries.sql splits these
-- separately, but the interesting question is whether daily deals sell things the store can't.
select coalesce(data->>'source', '(none)')   as source,
       coalesce(data->>'category', '(none)') as category,
       (data->>'is_book')::boolean           as is_book,
       count(*)                              as purchases,
       count(distinct player_id)             as buyers,
       -sum(amount)                          as gold_spent,
       round(avg(-amount))                   as avg_price
from v_events
where event = 'item_purchased'
group by 1, 2, 3
order by purchases desc;

-- Time from session start to first purchase — how long the shop takes to become interesting.
with firsts as (
  select e.session_id,
         min(e.occurred_at) filter (where e.event = 'item_purchased') as first_buy,
         s.started_at
  from v_events e
  join v_sessions s using (session_id)
  where s.started_at is not null
  group by 1, 3
)
select count(*) filter (where first_buy is not null)                          as sessions_with_purchase,
       count(*)                                                               as sessions,
       round(percentile_cont(0.5) within group (
             order by extract(epoch from (first_buy - started_at)) / 60.0)::numeric, 1) as median_minutes_to_first_buy
from firsts;


-- ═══ PART 7 — Mining raw_log ═════════════════════════════════════════════════
-- raw_log is the last 20000 chars of the player's daily log file, format "HH:MM:SS - message"
-- in the player's LOCAL time with no date and no timezone. Useful for narrative detail and for
-- catching things the event taxonomy misses; useless for absolute timing across players.

-- Reusable exploded form. Everything below selects from this.
create or replace view v_log_lines as
select s.session_id,
       s.player_id,
       s.platform,
       s.started_at,
       n                                                                 as line_no,
       substring(trim(line) from '^(\d{2}:\d{2}:\d{2})')::time           as local_time,
       regexp_replace(trim(line), '^\d{2}:\d{2}:\d{2} - ', '')           as msg
from v_sessions s,
     lateral regexp_split_to_table(coalesce(s.raw_log, ''), E'\r?\n') with ordinality as t(line, n)
where trim(line) <> '';

-- What hour of their own local day do people play? The one genuinely useful thing the
-- unzoned timestamps give you, since it's relative to the player either way.
select extract(hour from local_time)::int as local_hour,
       count(*)                  as log_lines,
       count(distinct session_id) as sessions
from v_log_lines
group by 1
order by 1;

-- Cross-check the log against the event stream. Large systematic gaps mean events are being
-- dropped in flight (or that the log line and the track() call don't fire together).
select l.session_id,
       count(*) filter (where l.msg like 'Sold "%')            as log_sales,
       (select count(*) from v_events e
         where e.session_id = l.session_id and e.event = 'painting_sold')  as event_sales,
       count(*) filter (where l.msg like 'Finished a %painting%') as log_paintings,
       (select count(*) from v_events e
         where e.session_id = l.session_id and e.event = 'painting_finished') as event_paintings
from v_log_lines l
group by 1
having count(*) filter (where l.msg like 'Sold "%') <> (
         select count(*) from v_events e
         where e.session_id = l.session_id and e.event = 'painting_sold')
order by 1;

-- Painting names players type. Pure texture, but the single best read on whether people are
-- engaging with the naming step or spamming through it.
select substring(msg from 'Sold "(.*)" for \d+ gold')       as painting_name,
       (substring(msg from 'for (\d+) gold'))::int          as gold,
       session_id
from v_log_lines
where msg like 'Sold "%'
order by gold desc
limit 100;

-- Do players rename their paintings at all, or leave defaults? Short/repeated names suggest not.
select painting_name, count(*) as times_sold, length(painting_name) as name_length
from (
  select substring(msg from 'Sold "(.*)" for \d+ gold') as painting_name
  from v_log_lines where msg like 'Sold "%'
) x
where painting_name is not null
group by 1, 3
order by times_sold desc, name_length
limit 50;

-- Books being read, pulled from the log (the event carries the title too, but this catches
-- sessions whose events were lost).
select substring(msg from 'Read a chapter of "(.*)" \(') as book_title,
       count(*)                   as chapters,
       count(distinct session_id) as sessions
from v_log_lines
where msg like 'Read a chapter of %'
group by 1
order by chapters desc;

-- Decorations by name from the log, admired vs used.
select regexp_replace(regexp_replace(msg, '^(Admired|Used) ', ''), ' \(.*\)$', '') as decoration,
       count(*) filter (where msg like 'Admired %') as admired,
       count(*) filter (where msg like 'Used %')    as used,
       count(distinct session_id)                   as sessions
from v_log_lines
where msg like 'Admired %' or msg like 'Used %'
group by 1
order by admired + used desc;

-- Longest gaps between consecutive log lines within a session — where the game goes quiet.
-- A pile of long gaps means idle time, which for an ambient desktop game may be fine, but it
-- separates "played for 40 minutes" from "left it open for 40 minutes".
with gaps as (
  select session_id, local_time,
         local_time - lag(local_time) over (partition by session_id order by line_no) as gap
  from v_log_lines
)
select round(avg(extract(epoch from gap)))                                  as avg_gap_seconds,
       percentile_cont(0.5) within group (order by extract(epoch from gap)) as median_gap_seconds,
       count(*) filter (where gap > interval '10 minutes')                  as gaps_over_10min,
       count(*)                                                             as total_gaps
from gaps
where gap is not null and gap > interval '0';


-- ═══ PART 8 — Feedback and survey content ════════════════════════════════════

-- Feedback with the player's context attached, so you know whether a complaint came from
-- someone who played 3 minutes or 3 hours.
select f.created_at,
       f.player_id,
       round(f.playtime_seconds / 60.0, 1) as minutes_when_sent,
       (select count(*) from v_sessions s where s.player_id = f.player_id) as their_sessions,
       (select count(*) from v_events e
         where e.session_id = f.session_id and e.event <> 'session_start')  as events_that_session,
       f.message
from v_feedback f
order by f.created_at desc;

-- Survey answers grouped into one row per submission, so you read a person's whole set at once
-- rather than four disconnected rows.
select session_id, player_id,
       min(created_at) as submitted_at,
       string_agg(question || E'\n  -> ' || coalesce(nullif(answer, ''), '(skipped)'),
                  E'\n' order by created_at) as responses
from v_survey_answers
group by 1, 2
order by submitted_at desc;

-- Survey completion funnel — how far into the four questions people get.
with per_session as (
  select session_id,
         count(*) as questions_reached,
         count(*) filter (where coalesce(answer, '') <> '') as questions_answered
  from v_survey_answers
  group by 1
)
select questions_reached,
       count(*)                          as sessions,
       round(avg(questions_answered), 1) as avg_actually_answered
from per_session
group by 1
order by 1;


-- ═══ PART 9 — Deleting pre-cutoff rows (only if you really want to) ══════════
-- You said filtering is enough, and PART 0's views already do that — so you probably never
-- need this. It's here because you asked. There is no undo and no soft-delete column; once
-- these run the old rows are gone. Run the preview first and read the numbers.

-- Preview: exactly what each delete would remove.
select 'sessions' as tbl, count(*) as would_delete, min(created_at) as oldest, max(created_at) as newest
from sessions where created_at < analytics_cutoff()
union all select 'events',         count(*), min(created_at), max(created_at) from events         where created_at < analytics_cutoff()
union all select 'feedback',       count(*), min(created_at), max(created_at) from feedback       where created_at < analytics_cutoff()
union all select 'survey_answers', count(*), min(created_at), max(created_at) from survey_answers where created_at < analytics_cutoff()
order by 1;

-- The deletes. Wrapped in a transaction so you can inspect the counts and roll back. Replace
-- `rollback` with `commit` only once the counts match the preview above.
--
-- begin;
--   delete from events         where created_at < analytics_cutoff();
--   delete from sessions       where created_at < analytics_cutoff();
--   delete from feedback       where created_at < analytics_cutoff();
--   delete from survey_answers where created_at < analytics_cutoff();
-- rollback;   -- change to `commit` when you're sure
