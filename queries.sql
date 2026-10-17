-- Mini Me-mao analytics — example read queries.
--
-- Run these in the Neon SQL console (your own authenticated connection; the anonymous role the
-- game uses can only INSERT, never SELECT). They're a starting point — copy/tweak as needed.
--
-- Event taxonomy (see schema.sql / the game's analytics.gd):
--   category 'economy'  : item_purchased (amount=-price, data{item_id,category,is_book,source}),
--                         painting_sold (amount=+gold, data{name,star_tier}),
--                         daily_deal_reroll (amount=-cost), rack_upgrade_purchased (amount=-cost)
--   category 'activity' : painting_finished{category,xp}, chapter_read{title,skill,xp},
--                         book_finished{title}, painted_session{progress}, used_decor{deco},
--                         admired{deco}, had_snack{hunger_restored}, woke_up{energy_gained},
--                         inspired_mode, action_refused{reason}
--   category 'session'  : session_start{app_version,platform}
-- `amount` is the gold delta: negative = spent, positive = earned, null = non-economic.


-- ═══ Overview ════════════════════════════════════════════════════════════════

-- Headline totals.
select
  count(distinct player_id)                 as players,
  count(*)                                   as sessions,
  round(avg(duration_seconds) / 60.0, 1)     as avg_minutes,
  round(sum(duration_seconds) / 3600.0, 1)   as total_hours
from sessions;

-- Sessions & unique players per day.
select
  started_at::date                           as day,
  count(*)                                   as sessions,
  count(distinct player_id)                  as players,
  round(avg(duration_seconds) / 60.0, 1)     as avg_minutes
from sessions
group by 1
order by 1 desc;

-- Platform / build-version split.
select platform, app_version,
       count(*) as sessions, count(distinct player_id) as players
from sessions
group by 1, 2
order by sessions desc;


-- ═══ Engagement & retention ══════════════════════════════════════════════════

-- Per-player: how many sessions, total playtime, when last seen.
select
  player_id,
  count(*)                                   as sessions,
  round(sum(duration_seconds) / 60.0, 1)     as total_minutes,
  max(ended_at)                              as last_seen
from sessions
group by 1
order by total_minutes desc nulls last;

-- Session-length distribution.
select
  case
    when duration_seconds < 60   then 'a) < 1 min'
    when duration_seconds < 300  then 'b) 1-5 min'
    when duration_seconds < 900  then 'c) 5-15 min'
    when duration_seconds < 1800 then 'd) 15-30 min'
    else                              'e) 30+ min'
  end                                        as length_bucket,
  count(*)                                   as sessions
from sessions
group by 1
order by 1;

-- Retention: of the players who first played on a given day, how many came back later.
with firsts as (
  select player_id, min(started_at::date) as first_day
  from sessions group by 1
),
flags as (
  select f.first_day, f.player_id,
         bool_or(s.started_at::date > f.first_day) as returned
  from firsts f
  join sessions s using (player_id)
  group by 1, 2
)
select
  first_day,
  count(*)                                                        as new_players,
  count(*) filter (where returned)                               as came_back,
  round(100.0 * count(*) filter (where returned) / count(*), 1)   as pct_returned
from flags
group by 1
order by 1 desc;


-- ═══ Economy ═════════════════════════════════════════════════════════════════

-- Gold spent vs earned per player (net = earned - spent).
select
  player_id,
  -sum(amount) filter (where amount < 0)      as gold_spent,
   sum(amount) filter (where amount > 0)      as gold_earned,
   sum(amount)                                as net
from events
where category = 'economy'
group by 1
order by gold_spent desc nulls last;

-- Where the money goes: spend by economy event type.
select event,
       count(*)      as count,
       -sum(amount)  as gold_spent
from events
where category = 'economy' and amount < 0
group by 1
order by gold_spent desc;

-- Item purchases split by source (store vs daily_deal vs daily_book).
select
  data->>'source'  as source,
  count(*)          as purchases,
  -sum(amount)      as gold_spent
from events
where event = 'item_purchased'
group by 1
order by gold_spent desc;

-- Top purchased items.
select
  data->>'item_id'   as item,
  data->>'category'  as category,
  count(*)            as times_bought,
  -sum(amount)        as gold_spent
from events
where event = 'item_purchased'
group by 1, 2
order by times_bought desc
limit 20;

-- Do players spend at all? Share of sessions with >= 1 purchase.
select
  count(distinct session_id)                                          as sessions,
  count(distinct session_id) filter (where event = 'item_purchased')  as with_purchase,
  round(100.0 * count(distinct session_id) filter (where event = 'item_purchased')
        / nullif(count(distinct session_id), 0), 1)                    as pct
from events;


-- ═══ Content & activities ════════════════════════════════════════════════════

-- Paintings sold: volume and average price by star tier.
select
  (data->>'star_tier')::int  as star_tier,
  count(*)                     as sold,
  round(avg(amount))          as avg_price,
  sum(amount)                 as total_earned
from events
where event = 'painting_sold'
group by 1
order by 1;

-- Paintings made vs sold (sell-through).
select
  count(*) filter (where event = 'painting_finished') as made,
  count(*) filter (where event = 'painting_sold')     as sold
from events
where event in ('painting_finished', 'painting_sold');

-- Reading: chapters read and books finished, plus which skill lines people read.
select data->>'skill' as skill,
       count(*) filter (where event = 'chapter_read')  as chapters_read,
       count(*) filter (where event = 'book_finished') as books_finished
from events
where event in ('chapter_read', 'book_finished')
group by 1
order by chapters_read desc;

-- Which decorations get the most attention (admired vs actively used).
select
  data->>'deco'                                as decoration,
  count(*) filter (where event = 'admired')    as admired,
  count(*) filter (where event = 'used_decor') as used,
  count(*)                                      as total
from events
where event in ('admired', 'used_decor')
group by 1
order by total desc
limit 20;

-- Per-session activity averages (snacks, sleeps, paint sessions).
with per_session as (
  select session_id,
    count(*) filter (where event = 'had_snack')       as snacks,
    count(*) filter (where event = 'woke_up')         as sleeps,
    count(*) filter (where event = 'painted_session') as paint_sessions
  from events
  group by 1
)
select
  round(avg(snacks), 2)          as avg_snacks,
  round(avg(sleeps), 2)          as avg_sleeps,
  round(avg(paint_sessions), 2)  as avg_paint_sessions
from per_session;

-- What actions get refused (balance signal).
select data->>'reason' as reason, count(*) as count
from events
where event = 'action_refused'
group by 1
order by count desc;


-- ═══ Feedback & survey ═══════════════════════════════════════════════════════

-- Most recent feedback.
select created_at, player_id, app_version, playtime_seconds, message
from feedback
order by created_at desc
limit 50;

-- Survey answers grouped by question (skips blanks). The ZZZERO web dashboard's Survey tab shows the
-- same data, by question or grouped into one response per session.
select question, answer, player_id, app_version, created_at
from survey_answers
where coalesce(answer, '') <> ''
order by question, created_at desc;

-- Feedback/survey volume by app version — is a complaint coming from someone on an old build?
select app_version, count(*) as feedback_rows
from feedback
group by 1
order by 1 desc nulls last;

-- Feedback with each admin's Open/Close triage vote + derived consensus (votes come from the ZZZERO
-- web dashboard; a missing vote row means Open). OPEN = no Close votes, CLOSED = all 3, otherwise
-- "N/3 CLOSE". Same rules as the dashboard's Consensus column (web/src/lib/feedback.ts).
select f.created_at, f.app_version, f.message,
       coalesce(max(v.status) filter (where v.voter = 'memao'),   'open') as memao,
       coalesce(max(v.status) filter (where v.voter = 'bronsky'), 'open') as bronsky,
       coalesce(max(v.status) filter (where v.voter = 'ross'),    'open') as ross,
       case count(v.voter) filter (where v.status = 'close')
           when 0 then 'OPEN'
           when 3 then 'CLOSED'
           else (count(v.voter) filter (where v.status = 'close'))::text || '/3 CLOSE'
       end as consensus
from feedback f
left join feedback_votes v on v.feedback_id = f.id
group by f.id
order by f.created_at desc;


-- ═══ Debug: single-session timeline ══════════════════════════════════════════

-- Full ordered event stream for one session — paste a session_id from the sessions table.
select occurred_at, category, event, amount, data
from events
where session_id = '00000000-0000-0000-0000-000000000000'
order by occurred_at;
