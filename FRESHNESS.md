# Data Freshness Substrate

The freshness substrate is the uniform answer to one question, asked the same way
for **every** external source:

> For entity X, source Y — where did it come from, when was it last fetched, is it
> due for a refresh, and did it error?

Before this existed, every store invented its own freshness shape
(`external_metrics.fetched_at/valid_until`, `movie_availability_refreshes`,
`festival_ceremonies.scraped_at`, `movie_lists.last_import_at`, or — for TMDb
details and people — nothing but `updated_at`). You couldn't ask one question
across all sources. The substrate fixes that with one ledger + one API + one
registry. It is the `fetch_attempt` idea from #1053, generalized to every source.

> Scope: this is the **substrate only** (#1096 Phase B / #1090 Phase 1 / first
> child of #1010). It *tracks* freshness; it does not yet *act* on it. Demand-driven
> read-through, floor sweepers selecting via `due/2`, the budget governor, and TTL
> tuning are later phases (#1010 Phase 4–6 / #1090 Phase 5).

## The three parts

1. **`data_refreshes` ledger** — one polymorphic table, one row per
   `(entity_type, entity_id, source)`. Stores freshness *metadata only*; the actual
   values stay in `external_metrics`, `movies.omdb_data`, etc.
   Key columns: `fetched_at` (last successful fetch; NULL = never), `stale_after`
   (when it goes due; NULL = never due), `status`, `attempt_count`, `last_attempt_at`.

2. **`Cinegraph.Freshness` API**
   - `touch(entity_type, entity_id, source, status, opts)` — every fetch worker
     calls this after an attempt. `status` is `:ok | :empty | :error | :ineligible
     | :pending`. `opts[:base_date]` (movie `release_date` / person latest credit)
     drives the age-tiered TTL.
   - `stale?(entity_type, entity_id, source)` — is it due?
   - `due(source, limit, opts)` — stale entity ids, oldest-due first.

3. **`Cinegraph.Freshness.Policy` registry** — per-`(entity_type, source)`
   staleness strategy. **Pure** (no DB): the caller supplies `base_date`.

### Status vocabulary (#1010 §6)

| status | meaning | `stale_after` |
|---|---|---|
| `ok` | fetched successfully | from the strategy (age-tiered / fixed-cadence) |
| `empty` | source had nothing (subsumes the OMDb 90-day `fetch_attempt` cooldown) | strategy TTL × `@empty_multiplier` |
| `error` | fetch failed | backed-off retry (1h→2h→4h… cap 7d); escalates to `ineligible` after 8 |
| `ineligible` | precondition fails (e.g. no `imdb_id` → OMDb) or too many errors | `NULL` — never due |
| `pending` | seeded, not yet attempted | strategy TTL |

## How to add a source

One registry entry — that's it. The report, and (later) the floor and
read-through, pick it up automatically.

```elixir
# lib/cinegraph/freshness/policy.ex — @registry
"movie" => %{
  "my_new_source" => {:age_tiered, :release_date, %{new: 7, recent: 30, catalog: 180, old: 365}}
}
# or, for a flat cadence (lists/festivals):
"list" => %{"my_list_source" => {:fixed_cadence, 30}}
```

Strategies: `:age_tiered` (tier by entity age — movie by `release_date`, person by
`latest_credit`), `:fixed_cadence` (flat N days; per-entity override via
`metadata["ttl_override_days"]`), `:frozen` (never due). Room for more
(`:popularity_scaled`, …) with zero churn elsewhere.

Then have the source's fetch worker call `Freshness.touch(...)` with the right
`status` and `base_date`, and seed history into the ledger via
`mix cinegraph.freshness.backfill`.

## Commands

```bash
mix cinegraph.freshness.report          # per-source rollup table
mix cinegraph.freshness.report --json   # machine-readable (ProdRpc / daily check-in)
mix cinegraph.freshness.backfill        # seed the ledger from existing signals (idempotent)
```
