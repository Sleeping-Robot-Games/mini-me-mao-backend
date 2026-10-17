# mini-me-mao-backend

Analytics + feedback backend for the **Mini Me-mao** game. There is no server to deploy — the
game POSTs JSON directly to the **Neon Data API** (PostgREST). Access is anonymous (no player
sign-in), but **not header-less**: every request must carry a short-lived anonymous JWT issued by
**Neon Auth**, sent as `Authorization: Bearer <jwt>`. Neon resolves that token to the `anonymous`
Postgres role, and **insert-only Row-Level Security** is the security boundary.

> **Why the JWT?** We originally assumed a request with *no* `Authorization` header would run as
> the `anonymous` role automatically (as Neon's RLS docs imply). In practice the Data API rejects
> header-less requests with `missing authentication credentials: required authorization bearer
> token in JWT format`, even with `db_anon_role` correctly set to `anonymous` and the schema cache
> refreshed. Per Neon support, the Data API requires an auth provider to be configured before the
> anonymous role works at all — fully anonymous access still needs a JWT, it just doesn't require
> sign-in to obtain one. Enabling **Neon Auth** provides the endpoint that mints those tokens.

## Contents

- `schema.sql` — the `sessions`, `events`, `feedback`, and `survey_answers` tables plus insert-only
  RLS for the `anonymous` role. **Unchanged by the auth switch** — see note in step 4. Also the
  bot-only `feedback_votes` table and the `zzzero_bot` role's grants (see step 6).
- `queries.sql` — curated read queries (overview, retention, economy, content, feedback/survey) to
  run in the Neon SQL console; the "Reading your data" section below has a few inline examples.

## One-time setup

1. **Create a Neon project** (free tier) at <https://console.neon.tech>.

2. **Enable the Neon Data API:** in the project sidebar open **Data API** and enable it for your
   branch + database. Do **not** tick "grant public schema access" — that would hand the anonymous
   role `SELECT`; we want insert-only and grant that ourselves in step 4. Confirm the
   unauthenticated role is `anonymous` (the default). Copy the **API URL** it shows — it ends in
   `/rest/v1`, e.g.
   `https://ep-xxx-123.apirest.us-east-2.aws.neon.tech/neondb/rest/v1`.

3. **Enable Neon Auth** — this is the step that makes anonymous access work, and it is **separate**
   from the "Use Neon Auth" checkbox on the Data API screen (that checkbox alone is *not*
   sufficient). Open the **Auth** page in the console sidebar and run its own **Enable Neon Auth**
   flow. This provisions the `neon_auth` schema and stands up the token-issuing endpoint. Copy the
   **Auth URL** — it looks like
   `https://ep-xxx-auth.neonauth.us-east-2.aws.neon.tech/neondb/auth`.

4. **Run the schema:** open the Neon SQL Editor and paste/run `schema.sql`. **No SQL changes are
   needed for the auth switch** — the RLS policies and grants are still keyed to the role name
   `anonymous`, and the anonymous JWT's `role` claim resolves to that role via Neon's default
   `jwt_role_claim_key` (`.role`). (If your project's role name isn't literally `anonymous`, change
   it in the `GRANT`/`POLICY` blocks first.)

5. **Wire the game:** in `analytics.gd`, set `DATA_API_URL` to the step-2 URL (ending in
   `/rest/v1`, no trailing slash) and the Neon Auth base to the step-3 URL. The client fetches a
   fresh anonymous JWT from the Auth endpoint immediately before each send — see *Client behavior*
   below. Both URLs are safe to commit; RLS keeps the endpoint insert-only.

6. **(Optional) ZZZERO Discord bot access.** The studio's ZZZERO bot browses feedback and records
   admin triage votes (`feedback_votes`) through its `/mini feedback` command, connecting directly
   with its own least-privilege login role. Create the role **in the SQL Editor** — roles made from
   the console's Roles page join `neon_superuser` and get far more access than the bot needs:

   ```sql
   create role zzzero_bot with login password '<long random password>';
   ```

   Then re-run `schema.sql`; its final block grants `zzzero_bot` read-only access to `feedback` and
   read/write on `feedback_votes` (and skips itself if the role doesn't exist). Build the bot's
   connection string by taking the project's normal connection string and swapping in
   `zzzero_bot` and its password, then store it in the bot repo's `BOT_MINI_DATABASE_URL` secret.

## Verify before touching the game

Do this from a terminal before wiring the game. First mint an anonymous JWT, then use it.

```sh
DATA_API_URL="https://ep-xxx-123.apirest.us-east-2.aws.neon.tech/neondb/rest/v1"
AUTH_URL="https://ep-xxx-auth.neonauth.us-east-2.aws.neon.tech/neondb/auth"

# 1. Mint a short-lived anonymous JWT — a plain GET, no sign-in, no body. Returns
#    {"token": "<jwt>", "expires_at": <unix>}; the JWT carries a `role: anonymous` claim.
ANON_TOKEN=$(curl -sS "$AUTH_URL/token/anonymous" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
echo "$ANON_TOKEN"

# 2. Insert a row with the token — expect 201 Created:
curl -i -X POST "$DATA_API_URL/events" \
  -H "Authorization: Bearer $ANON_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d '{"player_id":1,"session_id":"00000000-0000-0000-0000-000000000001","category":"session","event":"session_start","data":{}}'

# 3. Try to read with the same token — expect an empty array (RLS is insert-only for anonymous):
curl -i "$DATA_API_URL/events?select=*" -H "Authorization: Bearer $ANON_TOKEN"
```

Then confirm the row is visible in the Neon SQL console (`select * from events;`).

The token endpoint is `GET {AUTH_URL}/token/anonymous`. Tokens expire in ~1 hour, so mint a fresh
one if step 2 later returns `401`.

## Client behavior (analytics.gd)

- **Events stream live.** As gameplay produces events they queue in memory and a ~5s timer ships
  them to `/events` in small batches (bursts like a bulk-sell coalesce into one POST). Feedback and
  survey submissions POST immediately on the button press.
- **Exit sends the session summary.** On quit the client flushes any last un-shipped events, then
  POSTs one `/sessions` row — playtime (`duration_seconds`), final `gold`, platform, version, and a
  tail-capped `raw_log` (this session's daily-log text, kept as a cheap human-readable backup). A
  crash loses at most the last few seconds of events.
- **Token is cached.** The client fetches an anonymous JWT and reuses it until shortly before its
  `expires_at` (~1h), refetching lazily on demand. Every POST goes out with `Authorization: Bearer
  <jwt>`. (Because a token is fetched within seconds of launch for the first event batch, the DB is
  already awake by the time the player quits.)

## Seeing data from the running game

Two gates decide whether the game actually sends anything:

1. **Release builds only.** `analytics.gd` no-ops when `OS.is_debug_build()` is true, which
   includes running from the Godot editor and debug exports. To see live data, make a **release
   export** — or, just for a quick test, temporarily set `_active = true` in `analytics.gd` (revert
   after). Nothing is sent from the editor.
2. **Player opt-in.** Sending is skipped if the player unticks "Share anonymous play data" in the
   in-game Settings (default on).

With both satisfied and the URLs set, the game streams events during play and POSTs the session
summary on exit; feedback and surveys send immediately on their button press.

## Reading your data

Query from the Neon SQL console (your authenticated connection — the `anonymous` role can't read).
Examples:

```sql
-- Gold spent per player (economy events have negative amount for spend)
select player_id, -sum(amount) as gold_spent
from events where category = 'economy' and amount < 0
group by player_id order by gold_spent desc;

-- What people buy, split by store vs daily deal
select data->>'source' as source, data->>'item_id' as item, count(*)
from events where event = 'item_purchased'
group by 1, 2 order by count desc;

-- Paintings made and average sale price
select count(*) filter (where event = 'painting_finished') as made,
       avg(amount) filter (where event = 'painting_sold')  as avg_sale
from events;

-- Average session length
select avg(duration_seconds) from sessions;

-- Survey answers grouped by question (skip blanks)
select question, count(*) filter (where coalesce(answer, '') <> '') as answered, answer
from survey_answers
where coalesce(answer, '') <> ''
order by question, created_at desc;
```

## Troubleshooting

- **`NEON_AUTH_SCHEMA_NOT_FOUND` when enabling Neon Auth on an existing project.** This was a
  Neon-side provisioning bug for us: the Auth enable flow failed to create the `neon_auth` schema
  on an already-existing project, and no config change fixed it. **Recreating the project from
  scratch** (fresh project → enable Data API → enable Neon Auth → run `schema.sql`) resolved it.
- **`missing authentication credentials: required authorization bearer token in JWT format`.** The
  request reached the Data API with no valid JWT. Make sure Neon Auth is enabled (step 3) and the
  request carries `Authorization: Bearer <jwt>` from a *non-expired* token (~1h lifetime).
- **`401`/`403` on insert with a valid token.** Check that `schema.sql` ran (RLS policy + `grant
  insert ... to anonymous` + `grant usage on schema public to anonymous`) and that the token's
  `role` claim is `anonymous`.

## Caveats

- **Free tier scales to zero.** After a period of idle, the first request wakes the compute and
  can take a few seconds. Because events now stream from launch, that wake happens early (on the
  first batch) rather than at exit, so the session-summary POST at quit is normally hitting an
  already-warm DB. A brand-new session that quits within the first few seconds could still catch a
  cold start against the ~2s per-request timeout; raise `_FLUSH_TIMEOUT_SEC` in `analytics.gd` if
  that matters.
- **The endpoint is effectively public.** Anyone can mint an anonymous JWT (that's the point — no
  sign-in), so the write endpoint is open to anyone who has the URLs. RLS keeps it insert-only
  (they can't read or modify anything). Fine to start; add Neon/edge rate-limiting if abused.
- **Data is anonymous.** Rows are keyed by `player_id`, a random per-install id — there is no
  personal information unless a player types some into the feedback box.
