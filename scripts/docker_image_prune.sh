#!/usr/bin/env bash
#
# docker_image_prune.sh — reclaim host disk by removing stale Docker images (#1122).
#
# Background: the July 2026 disk-full outage (#1121) forced a manual
# `docker image prune -a`, which deleted the app images that were in use.
# This script automates weekly pruning so that never has to be done by hand again.
#
# `docker image prune -a` removes images not referenced by ANY container
# (running or stopped). The active app image is always backed by kamal's running
# container, so it is never a prune candidate — no explicit exclude needed.
# The `until=168h` filter additionally spares anything created in the last 7 days.
# Kamal's own old-container/image cleanup is left untouched.
#
# Install via launchd — see scripts/launchd/com.cinegraph.docker-prune.plist.
#
set -euo pipefail

LOG_FILE="${DOCKER_PRUNE_LOG:-$HOME/Library/Logs/cinegraph-docker-prune.log}"
mkdir -p "$(dirname "$LOG_FILE")"

# POSIX timestamp without relying on GNU date flags.
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() { echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"; }

if ! command -v docker >/dev/null 2>&1; then
  log "ERROR: docker not found on PATH; skipping prune"
  exit 1
fi

log "Starting docker image prune (-a, until=168h)"

if output=$(docker image prune -a -f --filter "until=168h" 2>&1); then
  # `docker image prune` prints a "Total reclaimed space" line on success.
  echo "$output" | tee -a "$LOG_FILE"
  log "Prune complete"
else
  status=$?
  log "ERROR: docker image prune failed (exit ${status})"
  echo "$output" | tee -a "$LOG_FILE"
  exit "$status"
fi
