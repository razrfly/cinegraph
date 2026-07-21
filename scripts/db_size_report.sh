#!/usr/bin/env bash
#
# db_size_report.sh — #1122 Session 2 size snapshot (READ-ONLY)
#
# Prints the table/index/total sizes for the four #1122 tables plus the whole
# database and host free disk. Used for the day-0 baseline and the 7-day
# flat-curve verification. Safe to run any time — pure reads.
#
# Usage (host-side, or `ssh $HOST 'bash -s' < this_file`):
#   scripts/db_size_report.sh
#   scripts/db_size_report.sh --db cinegraph_prod --port 5432
#
set -euo pipefail

# launchd runs with a minimal PATH; psql lives in the Homebrew keg on the host.
command -v psql >/dev/null 2>&1 || export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"

DB=cinegraph_prod
PORT=5432
PGHOST=127.0.0.1
PGUSER=holden

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)   DB="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --host) PGHOST="$2"; shift 2 ;;
    --user) PGUSER="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

CONN="host=$PGHOST port=$PORT user=$PGUSER dbname=$DB"

echo "== db_size_report $(date -u '+%Y-%m-%dT%H:%M:%SZ') db=$DB =="

psql "$CONN" -X -c "
SELECT c.relname                                        AS table,
       pg_size_pretty(pg_table_size(c.oid))             AS table_incl_toast,
       pg_size_pretty(pg_indexes_size(c.oid))           AS indexes,
       pg_size_pretty(pg_total_relation_size(c.oid))    AS total,
       c.reltuples::bigint                              AS rows_est
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('movie_availability_refreshes','movie_watch_providers',
                    'api_lookup_metrics','data_refreshes')
ORDER BY pg_total_relation_size(c.oid) DESC;"

psql "$CONN" -X -c "SELECT pg_size_pretty(pg_database_size('${DB}')) AS database_total;"

echo "-- host free disk --"
df -h / 2>/dev/null || true
