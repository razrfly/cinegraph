# Scripts Directory

Organized development and utility scripts for the Cinegraph project.

## Directory Structure

```
scripts/
├── analysis/          # Data analysis and investigation scripts
├── data_import/       # Database population and import utilities
├── testing/          # Testing and validation scripts
├── launchd/          # macOS launchd job definitions (host automation)
├── archive/          # Archived temporary/debug scripts (moved from root)
├── *.sh             # Shell utilities (clear_database.sh, etc.)
└── *.exs            # Elixir utility scripts
```

## Host automation

### `docker_image_prune.sh` + `launchd/com.cinegraph.docker-prune.plist`

Weekly Docker image prune on the host (#1122). The July 2026 disk-full outage
(#1121) forced a manual `docker image prune -a`, which deleted images that were
in use; this automates the prune so it never has to be run by hand again.

`docker image prune -a -f --filter "until=168h"` removes only images not backing
any container (running or stopped) **and** older than 7 days. The active app
image is always backed by kamal's running container, so it is never a prune
candidate — no explicit exclude is needed. Kamal's own old-container cleanup is
left as-is.

Install on the host (times in the plist are host-local, not UTC):

```bash
cp scripts/launchd/com.cinegraph.docker-prune.plist ~/Library/LaunchAgents/
# edit the copy: replace __CINEGRAPH_REPO__ with the repo's absolute path on the host
launchctl load -w ~/Library/LaunchAgents/com.cinegraph.docker-prune.plist
```

Uninstall:

```bash
launchctl unload -w ~/Library/LaunchAgents/com.cinegraph.docker-prune.plist
rm ~/Library/LaunchAgents/com.cinegraph.docker-prune.plist
```

Logs: `~/Library/Logs/cinegraph-docker-prune.log` (script) and
`/tmp/cinegraph-docker-prune.{out,err}.log` (launchd stdout/stderr).

## Database reclaim (#1122 Session 2)

One-time host-side reclaim of the ~8.5–11 GB of dead JSONB payloads left in old rows
after #1122 Session 1 capped the writers. Both scripts run against the **direct**
Postgres port 5432 (never PgBouncer 6432) and are safe to pipe in over SSH without a
host-side git pull:

```bash
HOST=192.168.1.205
ssh "$HOST" 'bash -s' < scripts/db_size_report.sh                      # baseline / verification (read-only)
```

### `strip_availability_payloads.sh`

Batched, idempotent, resumable strip of the write-only `region_payload` /
`provider_payload` blobs from `metadata`. Nothing in `lib/` reads them; error rows
(`metadata = {"error": ...}`) and already-stripped rows are preserved because the
`WHERE metadata ? '<key>'` filter skips them. Models the id-range / half-open-window /
sleep discipline of `lib/cinegraph/maintenance/backfill_freshness.ex:297`, with a
periodic `CHECKPOINT` + plain `VACUUM` so the file doesn't balloon before the final
`VACUUM FULL` compacts it.

```bash
# Dry-run first (counts only), then the real strip. Smaller table first as a rehearsal.
ssh "$HOST" 'bash -s' < scripts/strip_availability_payloads.sh -- \
  --table movie_watch_providers --key provider_payload --dry-run
ssh "$HOST" 'bash -s' < scripts/strip_availability_payloads.sh -- \
  --table movie_watch_providers --key provider_payload
ssh "$HOST" 'bash -s' < scripts/strip_availability_payloads.sh -- \
  --table movie_availability_refreshes --key region_payload
```

After each strip: pause the writer queue in `kamal console`
(`Oban.pause_queue(queue: :movie_availability)`), run
`VACUUM FULL <table>;` on port 5432 to reclaim the heap, then
`Oban.resume_queue(queue: :movie_availability)`. Full runbook: issue #1122.

### `db_size_report.sh`

Read-only snapshot of the four #1122 tables + `pg_database_size` + `df -h`. Run daily
through the 7-day verification window to confirm the curves stay flat.

## Guidelines

- Keep the project root clean of temporary files
- Use proper subdirectories for script organization
- Archive old debugging/temporary scripts instead of deleting
- Document script purposes in comments or README files

## Archived Files

The `archive/` directory contains temporary debugging and test scripts that were previously cluttering the project root. These files have been preserved but moved out of the main context to improve performance.