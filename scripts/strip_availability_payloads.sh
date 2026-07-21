#!/usr/bin/env bash
#
# strip_availability_payloads.sh — #1122 Session 2 batched JSONB payload strip
#
# One-time reclaim: remove the write-only `region_payload` / `provider_payload`
# blobs left in the `metadata` JSONB of the two churn-heaviest tables by rows
# written before #1122 Session 1 capped the writers (commit cb2ff2d1).
#
# Nothing in lib/ reads these payloads (verified twice); product reads touch only
# scalar columns. Error rows written by `record_availability_error` carry
# metadata = {"error": ...} and are PRESERVED — the WHERE clause keys on the
# payload key existing, so error rows and already-stripped ('{}') rows are skipped.
#
# Runs host-side against the DIRECT Postgres port 5432 (never PgBouncer 6432 —
# these are plain autocommit UPDATEs, but we keep the maintenance-port discipline
# so a follow-on VACUUM/VACUUM FULL uses the same session semantics). Each batch
# is its own autocommit statement over a half-open id window [lo, hi); a short
# sleep throttles, and every N batches a CHECKPOINT + plain VACUUM lets the dead
# tuples be reused in-file so the table doesn't balloon before the final
# VACUUM FULL compacts it (the #1121 CHECKPOINT discipline).
#
# Idempotent + resumable: re-running skips rows already at '{}' via the
# `metadata ? '<key>'` filter, so an interrupted run just continues.
#
# Model: lib/cinegraph/maintenance/backfill_freshness.ex:297 (id-range / half-open
# window / sleep), reimplemented as host psql.
#
# Usage (run FROM the host, or piped in via `ssh $HOST 'bash -s' < this_file -- ...`):
#
#   scripts/strip_availability_payloads.sh \
#     --table movie_watch_providers --key provider_payload
#
#   scripts/strip_availability_payloads.sh \
#     --table movie_availability_refreshes --key region_payload
#
# Options:
#   --table T          target table (required): movie_watch_providers | movie_availability_refreshes
#   --key K            JSONB key to strip (required): provider_payload | region_payload
#   --batch N          id-window width per statement (default 100000)
#   --sleep S          seconds to sleep between batches (default 0.2)
#   --vacuum-every N   CHECKPOINT + VACUUM the table every N batches (default 50; 0 disables)
#   --min-id N         start id (default 0; use to resume)
#   --dry-run          count matching rows per window, update nothing
#   --db NAME          database (default cinegraph_prod)
#   --port P           port (default 5432 — the DIRECT port; do NOT use 6432)
#   --host H           psql host (default 127.0.0.1)
#   --user U           psql user (default holden)
#
set -euo pipefail

TABLE=""
KEY=""
BATCH=100000
SLEEP=0.2
VACUUM_EVERY=50
MIN_ID=0
DRY_RUN=0
DB=cinegraph_prod
PORT=5432
PGHOST=127.0.0.1
PGUSER=holden

while [[ $# -gt 0 ]]; do
  case "$1" in
    --table)        TABLE="$2"; shift 2 ;;
    --key)          KEY="$2"; shift 2 ;;
    --batch)        BATCH="$2"; shift 2 ;;
    --sleep)        SLEEP="$2"; shift 2 ;;
    --vacuum-every) VACUUM_EVERY="$2"; shift 2 ;;
    --min-id)       MIN_ID="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --db)           DB="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --host)         PGHOST="$2"; shift 2 ;;
    --user)         PGUSER="$2"; shift 2 ;;
    --)             shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- validate: whitelist table + key so nothing arbitrary is interpolated into SQL ---
case "$TABLE:$KEY" in
  movie_watch_providers:provider_payload) ;;
  movie_availability_refreshes:region_payload) ;;
  *)
    echo "refusing: --table/--key must be one of the two known pairs" >&2
    echo "  movie_watch_providers        provider_payload" >&2
    echo "  movie_availability_refreshes region_payload" >&2
    exit 2 ;;
esac
if [[ "$PORT" == "6432" ]]; then
  echo "refusing: port 6432 is PgBouncer; maintenance must use the direct port 5432" >&2
  exit 2
fi
if [[ ! "$BATCH" =~ ^[1-9][0-9]*$ ]]; then
  echo "refusing: --batch must be a positive integer (got '${BATCH}')" >&2
  exit 2
fi

PSQL=(psql "host=$PGHOST port=$PORT user=$PGUSER dbname=$DB" -v ON_ERROR_STOP=1 -qtAX)

# scalar helper
q() { "${PSQL[@]}" -c "$1"; }

# Preflight CHECKPOINT authority before touching any rows. A real strip issues
# CHECKPOINT (superuser or pg_checkpoint only); if the role lacks it, the first
# checkpoint would abort mid-run after rows are already updated. Dry-runs and
# runs with vacuuming disabled never checkpoint, so they skip this guard.
if [[ "$DRY_RUN" -ne 1 && "$VACUUM_EVERY" -ne 0 ]]; then
  can_checkpoint="$(q "SELECT rolsuper OR pg_has_role(current_user, 'pg_checkpoint', 'member') FROM pg_roles WHERE rolname = current_user;")"
  if [[ "$can_checkpoint" != "t" ]]; then
    echo "refusing: role '${PGUSER}' lacks CHECKPOINT privilege (needs superuser or pg_checkpoint)." >&2
    echo "  grant it, or re-run with --vacuum-every 0 to skip the in-run CHECKPOINT+VACUUM." >&2
    exit 2
  fi
fi

MAX_ID="$(q "SELECT COALESCE(MAX(id), 0) FROM ${TABLE};")"
echo "== ${TABLE}: strip '${KEY}' =="
echo "   max(id)=${MAX_ID} batch=${BATCH} sleep=${SLEEP}s vacuum_every=${VACUUM_EVERY} dry_run=${DRY_RUN}"
TOTAL_MATCH="$(q "SELECT count(*) FROM ${TABLE} WHERE metadata ? '${KEY}';")"
echo "   rows still holding '${KEY}': ${TOTAL_MATCH}"

if [[ "$MAX_ID" -eq 0 || "$TOTAL_MATCH" -eq 0 ]]; then
  echo "   nothing to do."
  exit 0
fi

changed_total=0
batch_no=0
lo="$MIN_ID"
while [[ "$lo" -le "$MAX_ID" ]]; do
  hi=$(( lo + BATCH ))
  batch_no=$(( batch_no + 1 ))

  if [[ "$DRY_RUN" -eq 1 ]]; then
    n="$(q "SELECT count(*) FROM ${TABLE} WHERE id >= ${lo} AND id < ${hi} AND metadata ? '${KEY}';")"
    [[ "$n" -gt 0 ]] && printf '   [dry] id [%d,%d): %d rows\n' "$lo" "$hi" "$n"
    changed_total=$(( changed_total + n ))
  else
    # RETURNING-count via a CTE; autocommit (single statement).
    n="$(q "WITH upd AS (
              UPDATE ${TABLE}
                 SET metadata = metadata - '${KEY}'
               WHERE id >= ${lo} AND id < ${hi}
                 AND metadata ? '${KEY}'
             RETURNING 1)
            SELECT count(*) FROM upd;")"
    if [[ "$n" -gt 0 ]]; then
      changed_total=$(( changed_total + n ))
      printf '   id [%d,%d): stripped %d (running total %d)\n' "$lo" "$hi" "$n" "$changed_total"
    fi
    if [[ "$VACUUM_EVERY" -gt 0 && $(( batch_no % VACUUM_EVERY )) -eq 0 ]]; then
      echo "   -- checkpoint + vacuum ${TABLE} (batch ${batch_no}) --"
      q "CHECKPOINT;" >/dev/null
      q "VACUUM ${TABLE};" >/dev/null
    fi
  fi

  lo="$hi"
  # sleep only when there is more work
  if [[ "$lo" -le "$MAX_ID" ]]; then
    sleep "$SLEEP"
  fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== dry-run done: would strip ${changed_total} rows from ${TABLE} =="
else
  if [[ "$VACUUM_EVERY" -ne 0 ]]; then
    echo "   -- final checkpoint + vacuum ${TABLE} --"
    q "CHECKPOINT;" >/dev/null
    q "VACUUM ${TABLE};" >/dev/null
  fi
  remaining="$(q "SELECT count(*) FROM ${TABLE} WHERE metadata ? '${KEY}';")"
  echo "== done: stripped ${changed_total} rows from ${TABLE}; remaining with '${KEY}': ${remaining} =="
  echo "   next: pause :movie_availability, then VACUUM FULL ${TABLE};"
fi
