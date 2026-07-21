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

## Guidelines

- Keep the project root clean of temporary files
- Use proper subdirectories for script organization
- Archive old debugging/temporary scripts instead of deleting
- Document script purposes in comments or README files

## Archived Files

The `archive/` directory contains temporary debugging and test scripts that were previously cluttering the project root. These files have been preserved but moved out of the main context to improve performance.