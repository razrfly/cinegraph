# Maintenance commands

Cinegraph's maintenance work lives in `Cinegraph.Maintenance.*` modules so the
same code path runs from three places:

1. **Dev machine, ad-hoc**: `mix cinegraph.<task>` (thin wrapper)
2. **Prod node, autonomous**: Oban Cron sweeper that calls the same module
3. **Prod node, one-shot from dev**: SSH + `bin/cinegraph eval`

This document covers (3). Patterns (1) and (2) live in their respective
module docstrings.

## One-shot prod execution recipe

Set these once per shell session (or export them in your shell rc):

```sh
HOST="${REMOTE_SSH_HOST:-192.168.1.205}"
APP_BIN="/path/to/cinegraph/bin/cinegraph"
```

Then every recipe below reads:

```sh
ssh "$HOST" "$APP_BIN eval \"Cinegraph.Maintenance.<Module>.run(<opts>)\""
```

Replace `<Module>` and `<opts>` per task. Examples below.

> **`HOST`** defaults to `192.168.1.205` — the prod host the
> `mix db.pull_production` task SSHes to. Override with `REMOTE_SSH_HOST`.
>
> **`APP_BIN`** is the release binary on the prod box. The exact path depends
> on your deploy layout. If unknown, log in and run
> `find / -name 'cinegraph' -path '*/bin/*' 2>/dev/null` once.

## Available commands

### Festival person-resolver backfill

Drains `person_required_nomination_missing_person` (was 91.58% RED).

```sh
# Full backfill — ~11k jobs, drains over hours on :maintenance queue
ssh "$HOST" "$APP_BIN eval \"Cinegraph.Maintenance.ResolvePersons.run([])\""

# Dry-run (count only)
ssh "$HOST" "$APP_BIN eval \"Cinegraph.Maintenance.ResolvePersons.run([dry_run: true])\""

# Scope to one organization
ssh "$HOST" "$APP_BIN eval \"Cinegraph.Maintenance.ResolvePersons.run([org: \\\"AMPAS\\\", limit: 100])\""
```

Returns `{:ok, %{found: N, enqueued: M, failed: 0, dry_run: false}}`.

### Canonical-list biography backfill

Drains `missing_biography` (currently 100% of ~23k canonical-list people).

```sh
# Full backfill — ~23k jobs, TMDb-rate-limited
ssh "$HOST" "$APP_BIN eval \"Cinegraph.Maintenance.RefreshBiographies.run([])\""

# Smoke test (5 jobs)
ssh "$HOST" "$APP_BIN eval \"Cinegraph.Maintenance.RefreshBiographies.run([limit: 5])\""
```

## Autonomous cron-driven sweepers

All backfills run automatically via `Oban.Plugins.Cron` (`config/config.exs`):

| Cron (UTC) | Worker | Drains | Cap |
|---|---|---|---|
| `5 5 * * *` | `CompletenessSnapshotWorker` | daily completeness snapshot + verdict log line | — |
| `30 5 * * *` | `BiographyRefreshSweeper` | canonical-list biographies | 5,000/day |
| `35 5 * * *` | `ProfileDataRefreshSweeper` | canonical-list `profile_path` + `known_for_department` | 3,000/day |
| `0 6 * * *` | `FestivalPersonResolverSweeper` | nominations missing `person_id` | 2,000/day |
| `30 6 * * *` | `OmdbBackfillSweeper` | movies missing OMDb (canonical first) | 5,000/day |
| `0 7 * * *` | `ImdbIdRepairSweeper` | movies missing `imdb_id` | 5,000/day |
| `0 4 * * 0` | `ZeroCreditsCleanupSweeper` | enqueue refetch for orphan people | 200/run |
| `0 4 * * 1` | `ZeroCreditsCleanupDeleteSweeper` | hard-delete still-orphaned rows | 200/run |
| `0 2 * * *` | `FestivalSyncSweeper` | discover + import new festival ceremonies (#745 Phase 2) | (uncapped — ~15 events/day) |
| `*/4 * * * *` | `HealthCacheWarmer` | keep `:health_cache` warm so `/admin/health` cold-paint stays sub-second (#745 Phase 3.3) | — |
| `0 3 * * *` | `PersonQualityScoreWorker` (`daily_incremental`) | PQS daily delta | (worker-paged) |
| `0 2 * * SUN` | `PersonQualityScoreWorker` (`weekly_full`) | PQS weekly full recalc | (worker-paged) |
| `0 1 1-7 * SUN` | `PersonQualityScoreWorker` (`monthly_deep`) | PQS monthly deep recalc | (worker-paged) |
| `0 */6 * * *` | `PersonQualityScoreWorker` (`health_check`) | PQS health check | — |
| `0 */12 * * *` | `PersonQualityScoreWorker` (`stale_cleanup`) | PQS stale rows | — |

You don't need to run the one-shot mix tasks unless you want to drain faster
than the daily caps allow, or you want to debug a specific batch.

## Available one-shot commands

The `Cinegraph.Maintenance.*` modules behind each sweeper also have:
- a `mix cinegraph.<thing>` wrapper for ad-hoc dev runs against the local DB
- `bin/cinegraph eval "Cinegraph.Maintenance.<Thing>.run([])"` for one-shots against prod

| Maintenance task | Mix wrapper |
|---|---|
| Festival person-resolver | `mix cinegraph.festivals.resolve_persons` |
| Biography refresh | `mix cinegraph.people.refresh_biographies` |
| Profile data refresh | `mix cinegraph.people.refresh_profile_data` |
| OMDb null backfill | `mix cinegraph.movies.backfill_omdb` |
| IMDb-id repair | `mix cinegraph.movies.repair_imdb_ids` |
| Zero-credits cleanup | `mix cinegraph.people.cleanup_zero_credits [--phase enqueue\|delete]` |
| Festival sync (discover + import) | `mix cinegraph.festivals.sync` |

The sweeper tasks above (festival resolver, biography/profile refresh, OMDb backfill, IMDb-id repair, zero-credits cleanup, festival sync) accept `--dry-run` (count only) and `--limit N` (cap enqueues).

The tasks below take their own positional args / flags as shown — `--dry-run` and `--limit` do **not** apply.

| Targeted task | Mix wrapper |
|---|---|
| Per-id TMDb refresh (drawer button equivalent) | `mix cinegraph.refresh.person <id> [<id>...]` |
| Per-id OMDb refresh (drawer button equivalent) | `mix cinegraph.refresh.omdb <movie_id> [...]` |
| 30-day completeness chart data | `mix cinegraph.completeness --history 30` |

## Reading prod stats from dev

\#739 Phase C ships ergonomic mix tasks that do the SSH + eval + parse for you.
Set `REMOTE_APP_BIN` once (in your shell rc or `.env`):

```sh
export REMOTE_APP_BIN=/path/to/cinegraph/bin/cinegraph
```

Then any of:

```sh
mix cinegraph.prod.health                  # /admin/health verdict, pretty JSON
mix cinegraph.prod.health --json | jq .status

mix cinegraph.prod.completeness            # one snapshot
mix cinegraph.prod.completeness --history 30   # 30-day series

mix cinegraph.prod.queues                  # Oban queue state

mix cinegraph.prod.activity                # 7 days
mix cinegraph.prod.activity --days 30
```

All four wrap `Cinegraph.ProdRpc.eval_json/1`, which uses the same SSH recipe
documented above — they're shortcuts, not a separate channel.

If you need to read something that doesn't have a `mix cinegraph.prod.*`
wrapper yet, fall back to the raw recipe:

```sh
ssh "$HOST" "$APP_BIN eval \"IO.puts(Jason.encode!(<expression>, pretty: true))\""
```

Or add a new `mix cinegraph.prod.<thing>` task following the existing pattern
(`lib/mix/tasks/cinegraph/prod/*.ex`) — they're ~25 lines each.

## Audits & ad-hoc reports

Read-only operational queries. Each has a local wrapper for the dev DB and,
where useful, a `cinegraph.prod.*` mirror that runs the analyzer inside the
running prod container via `Cinegraph.ProdRpc.eval_json/1` (no DB pull, no
SSH plumbing). All accept `--json` for piping to `jq`.

| Task | Prod variant | Purpose |
|---|---|---|
| `mix cinegraph.audit.year_discovery [--days N]` | `mix cinegraph.prod.audit.year_discovery [--days N]` | YearDiscoveryWorker health per festival, classified by failure mode (#759, #766) |
| `mix cinegraph.audit.imdb_event_id <ev> [--year YYYY]` | — | **Live IMDb fetch** for a single event ID; disambiguates `:source_unavailable` vs `:parser_breakage` vs `:bad_event_id` from the year-discovery audit. Documented exception to the pure-DB rule (see recipe below) (#772) |
| `mix cinegraph.audit.queue_failures --queue X [--worker Y] [--days N]` | `mix cinegraph.prod.audit.queue_failures --queue X [--worker Y] [--days N]` | Generic discard analysis for an Oban queue/worker; groups by error pattern with sample text (#760, #772) |
| `mix cinegraph.audit_people_scores` | — | Ground-truth auteurs score audit; flags ⚠️ failures after data imports / scoring formula changes |
| `mix cinegraph.drift <people\|movies\|festivals\|ratings> [--limit N] [--year YYYY] [--org SLUG]` | `mix cinegraph.prod.drift <people\|movies\|festivals\|ratings> [--limit N] [--year YYYY] [--org SLUG]` *(new in #772)* | Per-domain drift checks: `people`, `movies [--year YYYY]`, `festivals [--org SLUG]`, `ratings` (`Cinegraph.Health.Drift.*`) |
| `mix cinegraph.status` | — | Combined activity + queue state + last-sync snapshot |
| `mix cinegraph.queues` | `mix cinegraph.prod.queues` | Oban queue state (counts per queue × state, longest-running, failures last hour) |
| `mix cinegraph.activity [--days N]` | `mix cinegraph.prod.activity [--days N]` | Movies/people/ceremonies added per UTC day, plus job completions and failures |
| `mix cinegraph.completeness [--history N]` | `mix cinegraph.prod.completeness [--history N]` | Per-domain completeness % (movies / people / festivals / overall) |
| `mix cinegraph.health` | `mix cinegraph.prod.health` | `/admin/health` verdict (red/yellow/green) and the underlying drift map |
| `mix predictions.audit_festivals [--decade N]` | — | 1001 Movies with zero festival nominations, grouped by decade |
| `mix predictions.audit_coverage [--decade N]` | — | Data-completeness audit by decade for prediction candidates |
| `mix predictions.status` | — | Predictions accuracy + coverage snapshot |
| `mix predictions.backtest` | — | Backtest prediction algorithm against historical decades |

> **Mutating tasks documented elsewhere — do not run against prod for
> verification.** `mix predictions.{train,sweep,populate_cache}` write
> prediction state. `mix import_movies`, `mix import_canonical`,
> `mix omdb.enrich`, `mix tmdb.refresh_credits`, and the
> `cinegraph.{festivals,movies,people}.*` backfill tasks listed above
> mutate the DB or enqueue Oban jobs; they're documented in their own
> sections of this file. Use code inspection to confirm read-only-ness
> before adding a task to the audit table above.

## Adding a new audit

For any read-only operational query you'd otherwise write as a one-off
`mix run /tmp/foo.exs` script:

1. **Analyzer module** — put the logic in `lib/cinegraph/health/<thing>.ex`.
   Return a JSON-encodable map. Integrate with `Cinegraph.Health.Drift.result/5`
   only if it's genuinely a drift check (i.e. consumed by the verdict facade).
2. **Centralize Oban access** — if the analyzer reads `oban_jobs`, extend
   `Cinegraph.Health.ObanReader` rather than querying directly. The "single
   source of truth" comment at the top of that module is enforced by review.
3. **Local task** — `lib/mix/tasks/cinegraph/audit/<name>.ex` with
   `--days`/`--json` parsing, calling `Mix.Task.run("app.start")` first.
   Pretty-print a table for the no-flag case so the output is human-friendly.
4. **Prod task** — `lib/mix/tasks/cinegraph/prod/audit/<name>.ex` (~25 lines)
   using `Cinegraph.ProdRpc.eval_json/1`. Do **not** call `Mix.Task.run("app.start")`
   in prod tasks — it leaks logs into stdout that breaks `jq` piping. See
   `lib/mix/tasks/cinegraph/prod/health.ex` as a template.
5. **Document** — add a row to the table above. README points at this file;
   do not duplicate the docs.
6. **Pure DB only — with one documented exception.** Audits must be fast
   and side-effect-free; never mix live API/scrape data into a DB-backed
   audit. The exception is single-target diagnostic tools (e.g.
   `mix cinegraph.audit.imdb_event_id <ev>`) whose specific job is to
   root-cause **why** a DB-backed audit classified a row a certain way.
   Such tools live alongside other audits but are clearly marked in the
   moduledoc and the catalog above as live-HTTP. They take a single
   target as positional arg (not `--days`-style windowing), and they
   have no prod variant (calling IMDb from a dev terminal works
   identically anywhere).

## Conventions

- Maintenance modules return `{:ok, %{found, enqueued, failed, dry_run}}` so
  cron sweepers, mix tasks, and rpc calls can all introspect the result.
- They accept `:dry_run`, `:limit`, and task-specific options (e.g. `:org`).
- They never log via `Mix.shell()` (which doesn't exist in releases) — only
  `Logger.*`.
- They're idempotent. The Oban workers they enqueue are uniqueness-keyed so
  re-runs collapse.

When adding a new maintenance task, follow the same shape:

1. `Cinegraph.Maintenance.<Thing>.run/1` returning `{:ok, %{...}}`.
2. `Mix.Tasks.Cinegraph.<Thing>` thin wrapper that delegates and prints.
3. (Optional) `Cinegraph.Workers.<Thing>Sweeper` Oban worker that wraps
   `Maintenance.<Thing>.run([limit: N])` for autonomous draining.
4. Crontab entry in `config/config.exs` if applicable.
