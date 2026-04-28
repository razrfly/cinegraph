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

Both backfills also run automatically via `Oban.Plugins.Cron`
(`config/config.exs`):

| Cron | Worker | Cap |
|---|---|---|
| `30 5 * * *` | `BiographyRefreshSweeper` | 5,000 jobs/run |
| `0 6 * * *` | `FestivalPersonResolverSweeper` | 2,000 jobs/run |
| `5 5 * * *` | `CompletenessSnapshotWorker` | (writes daily snapshot + verdict log line) |

You don't need to run the one-shots above unless you want to drain faster
than the daily caps allow.

## Reading prod stats from dev

> Status: ⚠ partially implemented (see #739 Phase C). Today, you have two
> options:

**Option A — pull the DB and run mix tasks locally (slow, drift):**

```sh
mix db.pull_production
mix cinegraph.health
```

**Option B — RPC into prod for live numbers (no DB pull):**

```sh
# Health verdict
ssh "$HOST" "$APP_BIN eval \"IO.puts(Jason.encode!(Cinegraph.Health.Facade.compute_full_verdict(), pretty: true))\""

# Completeness snapshot
ssh "$HOST" "$APP_BIN eval \"IO.puts(Jason.encode!(Cinegraph.Health.Completeness.run(), pretty: true))\""

# Queue snapshot
ssh "$HOST" "$APP_BIN eval \"IO.puts(Jason.encode!(Cinegraph.Health.Queues.snapshot(), pretty: true))\""
```

A future `mix cinegraph.prod.health` wrapper will turn these into one-liners
(see #739 Phase C).

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
