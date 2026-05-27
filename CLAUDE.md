# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚠️ Version Control Policy
**DO NOT USE GIT COMMANDS** — the user manages all git operations. Never run `git add`, `git commit`, `git push`, or any other git command unless explicitly instructed.

## Common Commands

```bash
# Development
./start.sh                   # loads .env then starts server (preferred over mix phx.server directly)
iex -S mix phx.server        # interactive console + server

# Database
mix ecto.setup               # create + migrate + seed
mix ecto.reset               # drop + recreate + migrate + seed
mix ecto.migrate             # run pending migrations

# Testing
mix test                                          # all tests (excludes :integration tag by default)
mix test test/path/to/file_test.exs               # single file
mix test test/path/to/file_test.exs:42            # single test at line 42
mix test --only integration                       # integration tests only
mix test --exclude kamal                          # skip tests requiring kamal CLI

# Assets
mix assets.build             # compile 3 Tailwind themes + esbuild (dev)
mix assets.deploy            # minified + digested (prod)

# Formatting (run before committing)
mix format
```

## Architecture: Critical Patterns

### 1. `load_in_query: false` — JSONB blobs are never auto-loaded

`Movie` marks two fields excluded from every default query:

```elixir
field :tmdb_data, :map, load_in_query: false   # raw TMDb API response
field :omdb_data, :map, load_in_query: false   # raw OMDb API response
```

**Why:** These JSONB blobs are multi-megabyte. Before this fix (#923), every `Movies.get_movie/1` call shipped them over the wire, causing OOM crashes at scale.

**Consequence:** Anywhere you need `tmdb_data` or `omdb_data`, you must opt in explicitly:

```elixir
from m in Movie, where: m.id == ^id, select_merge: %{omdb_data: m.omdb_data}
```

Forgetting this opt-in is silent — the field returns `nil`, causing `has_data?/1` guards to always return false and burning API quota re-fetching already-enriched movies.

### 2. external_metrics — volatile ratings live here, not on movies

The `movies` table has no `vote_average`, `popularity`, or `revenue` columns. All external/volatile metrics live in `external_metrics` (one row per `movie_id × source × metric_type`):

| source | metric_type examples |
|---|---|
| `"tmdb"` | `rating_average`, `rating_votes`, `popularity_score`, `budget`, `revenue_worldwide` |
| `"omdb"` | `awards_summary`, `content_rating`, `revenue_domestic`, `fetch_attempt` |
| `"imdb"` | `rating_average`, `rating_votes` |
| `"rotten_tomatoes"` | `tomatometer` |
| `"metacritic"` | `metascore` |

Key API: `Cinegraph.Metrics` — `store_omdb_metrics/2`, `store_tmdb_metrics/2`, `upsert_metric/1`, `get_metric_value/3`.

A `fetch_attempt` row means "we tried but the API returned nothing" — used as a 90-day cooldown so the movie exits the sweeper backlog automatically.

### 3. ApiProcessors.Behaviour — pluggable external API pattern

Adding a new external data source means implementing `Cinegraph.ApiProcessors.Behaviour`:

```elixir
@callback process_movie(movie_id, opts) :: {:ok, movie} | {:error, reason}
@callback can_process?(movie) :: boolean()       # has required identifier?
@callback required_identifier() :: atom()         # :imdb_id, :tmdb_id, etc.
@callback has_data?(movie) :: boolean()           # already enriched?
@callback rate_limit_ms() :: non_neg_integer()
```

Implementations: `ApiProcessors.TMDb`, `ApiProcessors.OMDb`. Both use `select_merge` to opt into `load_in_query: false` fields before calling `has_data?`.

### 4. Maintenance module + Sweeper worker — the backfill pattern

Every data-quality backfill follows a two-layer pattern:

**Layer 1 — Maintenance module** (`lib/cinegraph/maintenance/`): pure logic, no scheduling. Provides `run(opts)` returning `{:ok, %{found:, enqueued:, failed:, dry_run:}}`. Callable from mix tasks and `iex`.

**Layer 2 — Sweeper worker** (`lib/cinegraph/workers/*_sweeper.ex`): thin Oban wrapper scheduled via cron, calls the maintenance module with a daily cap (typically 5,000).

```elixir
# lib/cinegraph/workers/omdb_backfill_sweeper.ex
use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3
def perform(_job), do: BackfillOmdb.run(limit: 5_000)
```

The sweeper cron block runs 5:30–7:30 AM UTC daily. Maintenance modules are safe to run manually in iex or via `bin/cinegraph eval` in production.

### 5. Health/Drift system — data quality monitoring

`Cinegraph.Health.Drift` tracks data completeness across 6 domains (`:movies`, `:people`, `:festivals`, `:ratings`, `:availability`, `:collaborations`). Each check returns:

```elixir
%{domain:, check:, status:, total_population:, affected_count:, affected_pct:, examples: [...]}
```

**Canonical scope**: all drift checks scope to `canonical_movies` (movies with `canonical_sources != '{}'`). Long-tail TMDb bulk imports are excluded — they legitimately lack OMDb/RT coverage and would pollute measurements. See `Cinegraph.Health.Scopes`.

**Caching**: checks cache for 35 minutes in Cachex (`:health_cache`), warmed every 30 min by `HealthCacheWarmer`. Don't call drift functions in hot paths.

**Facade**: `Cinegraph.Health.Facade.compute_full_verdict/1` runs all 6 domains concurrently via `Task.Supervisor.async_stream_nolink` with a 20s per-domain timeout.

### 6. V2 LiveView architecture — subdirectory decomposition

V2 LiveViews split into nested modules rather than monolithic files:

```text
live/movie_live/
  show_v2.ex                    # mount, handle_event, render
  show_v2/
    data.ex                     # DB queries and data loading
    presentation.ex             # formatting helpers (no DB calls)
    production_details.ex       # production crew/company rendering
  show_v2_availability.ex       # streaming providers (async component)

  index_v2.ex                   # orchestration only
  index_v2_components.ex        # stable render facade
  index_v2/
    search_handler.ex           # query building
    canonicalize.ex             # URL param normalization
    events.ex                   # event handler dispatch
  index_v2_components/
    filters.ex / active_chips.ex / card_helpers.ex
```

V1 (`show.ex`, `index.ex`) still exists as legacy fallback at `/movies/:slug/legacy`. All new feature work targets V2.

### 7. Filters pipeline

`Cinegraph.Movies.Filters.apply_filters/2` chains independent filter functions. Each is a no-op when its param is nil. Named bindings (`:score_cache`, `:credits`) prevent duplicate joins across the chain.

`Cinegraph.Movies.Query.CustomFilters` is the newer Flop-based variant taking a `%Params{}` struct. Both coexist.

Age filtering (`filter_by_max_age/2`) queries `external_metrics` for OMDb `content_rating` rows and `movie_release_dates` for TMDb certifications. Rating-to-age mapping lives in `Cinegraph.Movies.ContentRating`.

### 8. Production access via ProdRpc

`Cinegraph.ProdRpc` runs Elixir expressions in the production container via `kamal app exec`. Output must be JSON:

```elixir
ProdRpc.eval_json(~s|Jason.encode!(%{count: Repo.aggregate(Movie, :count)})|)
# → {:ok, %{"count" => 1156491}}
```

Kamal shell aliases: `kamal shell`, `kamal logs`, `kamal console` (remote IEx).

## Oban Queues & Concurrency

```text
tmdb: 5    omdb: 5    collaboration: 3    scraping: 3
festival_discovery: 1    metrics: 2    maintenance: 1
```

`maintenance` has concurrency 1 — sweepers serialize automatically. TMDb API rate-limit is 40 req/10s (250ms between jobs at concurrency 5).

## Test Patterns

- `Cinegraph.DataCase` — Ecto sandbox; call `allow(repo, self(), pid)` when spawning tasks in tests
- `Cinegraph.FestivalFixtures.plant_nomination!/1` — creates the full chain in one call: Person → Movie → Credit → Organization → Category → Ceremony → Nomination
- `Cinegraph.Scrapers.FestivalHttpStub` — ETS-backed HTTP stub; `set_response(url_fragment, {:ok, html})` then `reset!()` in teardown
- `Cinegraph.Images.R2Stub` — auto-initialized; real R2 calls are never made in test
- `:integration` tests are excluded by default; `:kamal` tests require the kamal CLI installed

## Adding Festivals & Awards Ceremonies

The `festival_events` table is the single source of truth. Add new festivals via:
1. Seeds (`priv/repo/seeds.exs`) or Admin UI (`/admin/festivals`)
2. Discover years: `YearDiscoveryWorker.queue_discovery("source_key")`
3. Import a year: `Cultural.import_festival_year("source_key", 2024)`
4. Bulk import: `AwardImportWorker.queue_sync_missing(org_id)`

No code changes needed — `Events.list_active_events/0` drives all festival discovery dynamically.

## Adding Canonical Movie Lists

The `movie_lists` table is the single source of truth. Add via:
1. Seeds (`MovieLists.seed_default_lists/0`) or Admin UI (`/admin/lists-manager`)
2. Fill: name, source_url (IMDb list URL), source_id, category, slug
3. Trigger import: `CanonicalImporter.import_list_by_key("source_key")`

## Environment Variables

```text
TMDB_API_KEY           TMDb API access
OMDB_API_KEY           OMDb API (Basic plan = 100k req/day)
DATABASE_URL           Production DB connection
OMDB_DAILY_BATCH_SIZE  RatingsRefreshWorker batch size (prod default: 100_000)
REPLICA_POOL_SIZE      Production read replica pool (prod default: 40)
CRAWLBASE_API_KEY      Static HTML scraping
CRAWLBASE_JS_API_KEY   JS-rendered scraping
```

Dev loads from `.env` via Dotenvy (`./start.sh` handles this). Test config uses hardcoded values in `config/test.exs`.
