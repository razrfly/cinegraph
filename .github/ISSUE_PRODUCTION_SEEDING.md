# Production Database Seeding Issue

## Problem Statement

The Cinegraph application has critical reference data defined in `priv/repo/seeds.exs` that is **not being populated in production**. This results in a production database missing essential data, causing feature failures and incomplete functionality.

### Current Situation

- **Development**: Seeds run successfully via `mix ecto.setup` and `mix ecto.reset`
- **Production**: Seeds are **never executed** after deployments
- **Impact**: Production database is missing:
  - Canonical movie lists (1001 Movies, Criterion Collection, etc.)
  - Festival event definitions (Oscars, Cannes, Venice, Berlin, Sundance, etc.)
  - Festival dates for 2024/2025
  - Metric definitions (30+ rating/award/cultural metrics)
  - Metric weight profiles (5 discovery profiles)

## Current Seed Data Inventory

### 1. Canonical Movie Lists (`MovieLists.migrate_hardcoded_lists/0`)
**Type**: Reference data
**Records**: 4 lists from `CanonicalLists` module
- `1001_movies` - 1001 Movies You Must See Before You Die
- `criterion` - The Criterion Collection
- `sight_sound_critics_2022` - BFI's Sight & Sound Critics' Top 100 (2022)
- `national_film_registry` - Library of Congress National Film Registry

**Implementation**: Idempotent via `Repo.get_by(MovieList, source_key: key)`

### 2. Festival Events (`Events.create_festival_event/1`)
**Type**: Reference data
**Records**: 7 major film festivals
- Academy Awards (Oscars) - Official source
- Cannes Film Festival - IMDb source
- Venice International Film Festival - IMDb source
- Berlin International Film Festival - IMDb source
- New Horizons International Film Festival - IMDb source
- Sundance Film Festival - IMDb source
- SXSW Film Festival - IMDb source

**Implementation**: Idempotent via `Events.get_by_source_key/1` check

### 3. Festival Dates (`Events.upsert_festival_date/1`)
**Type**: Reference data
**Records**: 14 festival dates (7 festivals × 2 years: 2024 completed, 2025 upcoming)

**Implementation**: Idempotent via `upsert_festival_date/1`

### 4. Metric Definitions (`priv/repo/seeds/metric_definitions.exs`)
**Type**: Reference data
**Records**: 30 metric definitions across 5 categories
- Ratings: IMDb, TMDb, Metacritic, Rotten Tomatoes (7 metrics)
- Popularity: Vote counts, TMDb popularity (3 metrics)
- Financial: Budget, revenue (3 metrics)
- Awards: Oscars, Cannes, Venice, Berlin (5 metrics)
- Cultural: Canonical lists, critics polls (7 metrics)
- People: Person quality score (1 metric)

**Implementation**: Idempotent via `Repo.insert_all/3` with `on_conflict: {:replace, ...}`

### 5. Metric Weight Profiles (`priv/repo/seeds/metric_weight_profiles.exs`)
**Type**: Reference data
**Records**: 5 discovery weight profiles
- Balanced (default)
- Award Winner
- Critics Choice
- Crowd Pleaser
- Cult Classic

**Implementation**: Idempotent via `Repo.insert_all/3` with `on_conflict: {:replace, ...}`, system profiles deleted first

## Why Seeds Don't Run in Production

### Development Behavior
```elixir
# mix.exs
"ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"]
```
Seeds run automatically in development via `mix ecto.setup`.

### Production Behavior
```elixir
# lib/cinegraph/release.ex
def migrate do
  load_app()
  for repo <- repos() do
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
  end
end
```
```bash
# fly.toml (commented out)
[deploy]
  # release_command = '/app/bin/migrate'
```
The release command only runs migrations, **not seeds**.

## Solution Strategies

### Strategy 1: Add Seeds to Release Task (RECOMMENDED)

**Approach**: Extend `Cinegraph.Release.migrate/0` to run seeds after migrations.

**Pros**:
- Simple implementation
- Runs automatically on every deployment
- Matches Phoenix conventions
- Seeds run in same transaction context as migrations
- No new infrastructure required

**Cons**:
- Seeds run on every deployment (mitigated by idempotency)
- Slightly longer deployment time (~2-5 seconds)

**Implementation**:
```elixir
# lib/cinegraph/release.ex
def migrate do
  load_app()

  for repo <- repos() do
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
  end

  # Run seeds after migrations
  seed()
end

def seed do
  # Ensure application is loaded
  load_app()

  # Load and execute seed file
  seed_script = Path.join([priv_dir(:cinegraph), "repo", "seeds.exs"])

  if File.exists?(seed_script) do
    IO.puts("Running seed script...")
    Code.eval_file(seed_script)
  end
end

defp priv_dir(app), do: "#{:code.priv_dir(app)}"
```

**Deployment Configuration**:
```toml
# fly.toml
[deploy]
  release_command = '/app/bin/migrate'
```

**Verification**:
All existing seeds are already idempotent:
- ✅ Canonical lists use `get_by_source_key/1` check
- ✅ Festival events use `get_by_source_key/1` check
- ✅ Festival dates use `upsert_festival_date/1`
- ✅ Metric definitions use `on_conflict: {:replace, ...}`
- ✅ Metric weight profiles delete system profiles first, then upsert

---

### Strategy 2: Data Migrations for Reference Data

**Approach**: Create dedicated migrations for each category of reference data.

**Pros**:
- Migrations are versioned and tracked
- Run exactly once per environment
- Clear audit trail in schema_migrations table
- Can be rolled back if needed

**Cons**:
- Reference data updates require new migrations
- Harder to update existing reference data
- Migrations become bloated with non-schema changes
- Violates separation of concerns (schema vs data)

**Implementation**:
```elixir
# priv/repo/migrations/20251120_seed_canonical_lists.exs
defmodule Cinegraph.Repo.Migrations.SeedCanonicalLists do
  use Ecto.Migration

  def up do
    # Run the canonical lists migration
    Code.eval_file("priv/repo/seeds.exs")
  end

  def down do
    # Optional: clean up seeded data
    execute "DELETE FROM movie_lists WHERE source_key IN ('1001_movies', 'criterion', 'sight_sound_critics_2022', 'national_film_registry')"
  end
end
```

**When to Use**:
- One-time reference data that rarely changes
- Critical data that must exist before app starts
- When rollback capability is essential

---

### Strategy 3: Separate Release Command for Seeds

**Approach**: Create a dedicated release task for seeding, run separately from migrations.

**Pros**:
- Seeds can be run independently of migrations
- Explicit control over when seeds run
- Can be triggered manually via `fly ssh console`

**Cons**:
- Requires manual intervention or separate CI/CD step
- Easy to forget to run seeds
- Two-step deployment process
- Coordination required between migration and seed execution

**Implementation**:
```elixir
# lib/cinegraph/release.ex
def seed do
  load_app()
  seed_script = Path.join([priv_dir(:cinegraph), "repo", "seeds.exs"])

  if File.exists?(seed_script) do
    IO.puts("Running seed script...")
    Code.eval_file(seed_script)
  end
end
```

```bash
# rel/overlays/bin/seed
#!/bin/sh
set -eu
cd -P -- "$(dirname -- "$0")"
exec ./cinegraph eval Cinegraph.Release.seed
```

**Deployment**:
```bash
# Manual step after deployment
fly ssh console -C "/app/bin/seed"
```

---

### Strategy 4: Application Startup Seeds

**Approach**: Run seeds automatically when the application starts.

**Pros**:
- Seeds always run on app startup
- No deployment configuration needed
- Works with any deployment method

**Cons**:
- Slows down application startup
- Seeds run on every application restart (not just deployments)
- Potential race conditions with multiple instances
- Not suitable for distributed deployments

**Implementation**:
```elixir
# lib/cinegraph/application.ex
def start(_type, _args) do
  # Run seeds on startup (only on primary node)
  if Mix.env() == :prod and node() == primary_node() do
    Cinegraph.Release.seed()
  end

  # ... rest of application start
end
```

**When to Use**:
- Single-instance deployments only
- Development/staging environments
- Not recommended for production

---

## Recommended Solution: Strategy 1 (Enhanced Release Task)

### Why This Approach?

1. **Idempotency**: All seeds are already idempotent, safe to run multiple times
2. **Simplicity**: Single source of truth in `seeds.exs`, no duplicate code
3. **Automation**: Runs automatically on every deployment, no manual steps
4. **Phoenix Conventions**: Matches standard Phoenix deployment patterns
5. **Minimal Changes**: Only requires updating `Release.migrate/0`
6. **Maintainability**: Easy to add new seed data in the future

### Implementation Checklist

- [ ] Update `lib/cinegraph/release.ex` to add `seed/0` function
- [ ] Update `migrate/0` to call `seed/0` after migrations
- [ ] Test locally with production build:
  ```bash
  MIX_ENV=prod mix release
  _build/prod/rel/cinegraph/bin/migrate
  ```
- [ ] Verify seeds are idempotent:
  ```bash
  # Run seeds twice, ensure no errors
  mix run priv/repo/seeds.exs
  mix run priv/repo/seeds.exs
  ```
- [ ] Enable release command in `fly.toml`:
  ```toml
  [deploy]
    release_command = '/app/bin/migrate'
  ```
- [ ] Test deployment to staging (if available)
- [ ] Deploy to production
- [ ] Verify seed data in production database:
  ```sql
  SELECT COUNT(*) FROM movie_lists;  -- Should be 4
  SELECT COUNT(*) FROM festival_events;  -- Should be 7
  SELECT COUNT(*) FROM festival_dates;  -- Should be 14
  SELECT COUNT(*) FROM metric_definitions;  -- Should be 30
  SELECT COUNT(*) FROM metric_weight_profiles WHERE is_system = true;  -- Should be 5
  ```
- [ ] Monitor deployment logs for seed execution
- [ ] Test application features that depend on seed data

### Migration Path

**Phase 1: Immediate Fix** (This PR)
- Implement Strategy 1 to populate production database
- Run seeds automatically on deployment

**Phase 2: Future Enhancement** (Optional)
- Consider Strategy 2 for critical reference data that rarely changes
- Keep Strategy 1 for frequently updated reference data (festival dates, etc.)

## Testing Strategy

### Local Testing
```bash
# Test seeds are idempotent
mix ecto.reset  # Creates fresh database and runs seeds
mix run priv/repo/seeds.exs  # Run seeds again
# Verify no errors and no duplicate data

# Test production release
MIX_ENV=prod mix release
_build/prod/rel/cinegraph/bin/migrate
# Verify seeds ran successfully
```

### Production Verification Queries
```sql
-- Canonical Lists
SELECT source_key, name, active FROM movie_lists ORDER BY name;

-- Festival Events
SELECT source_key, name, country, founded_year FROM festival_events ORDER BY import_priority DESC;

-- Festival Dates
SELECT fe.name, fd.year, fd.start_date, fd.end_date, fd.status
FROM festival_dates fd
JOIN festival_events fe ON fd.festival_event_id = fe.id
ORDER BY fd.year, fd.start_date;

-- Metric Definitions
SELECT category, COUNT(*) as count
FROM metric_definitions
WHERE active = true
GROUP BY category
ORDER BY category;

-- Metric Weight Profiles
SELECT name, is_default, is_system, active
FROM metric_weight_profiles
WHERE is_system = true
ORDER BY name;
```

## Related Files

- `/Users/holdenthomas/Code/paid-projects-2025/cinegraph/priv/repo/seeds.exs` - Main seed file
- `/Users/holdenthomas/Code/paid-projects-2025/cinegraph/priv/repo/seeds/metric_definitions.exs` - Metric definitions seed
- `/Users/holdenthomas/Code/paid-projects-2025/cinegraph/priv/repo/seeds/metric_weight_profiles.exs` - Weight profiles seed
- `/Users/holdenthomas/Code/paid-projects-2025/cinegraph/lib/cinegraph/release.ex` - Release tasks
- `/Users/holdenthomas/Code/paid-projects-2025/cinegraph/lib/cinegraph/canonical_lists.ex` - Canonical list definitions
- `/Users/holdenthomas/Code/paid-projects-2025/cinegraph/lib/cinegraph/movies/movie_lists.ex` - Movie list context
- `/Users/holdenthomas/Code/paid-projects-2025/cinegraph/fly.toml` - Deployment configuration
- `/Users/holdenthomas/Code/paid-projects-2025/cinegraph/rel/overlays/bin/migrate` - Migration script
- `/Users/holdenthomas/Code/paid-projects-2025/cinegraph/mix.exs` - Mix aliases (development only)

## References

### Elixir/Phoenix Best Practices
Based on research using Context7 and Phoenix documentation:

1. **Mix Tasks vs Release Tasks**: Mix is not available in production releases. All deployment tasks must use `Mix.Release` module.

2. **Release Commands**: Phoenix applications should use release commands in deployment configuration to run migrations and seeds.

3. **Idempotent Seeds**: Production seeds should always be idempotent (safe to run multiple times) using:
   - `Repo.get_by/2` checks before insertion
   - `Repo.insert_all/3` with `on_conflict` strategies
   - Upsert patterns with unique constraints

4. **Separation of Concerns**:
   - **Migrations**: Schema changes, table creation, index management
   - **Seeds**: Reference data, lookup tables, system configuration
   - **Data Migrations**: One-time data transformations (use sparingly)

5. **Production Deployment Pattern**:
   ```
   Build → Run Migrations → Run Seeds → Start Application
   ```

### Phoenix Release Documentation
- Release commands run in release environment without Mix
- Use `Code.eval_file/1` to execute seed scripts in releases
- Application must be loaded via `Application.load/1` before running seeds
- Use `Application.app_dir/2` to locate seed files in releases

### Ecto Best Practices
- Avoid running migrations and seeds in same transaction (different concerns)
- Use database constraints and unique indexes to enforce idempotency
- Prefer `insert_all` with conflict resolution over individual inserts for bulk data
- System-managed reference data should use boolean flags (`is_system: true`)

## Conclusion

**Recommended Approach**: Strategy 1 (Enhanced Release Task)

This solution:
- ✅ Automatically populates production database on deployment
- ✅ Leverages existing idempotent seed implementations
- ✅ Follows Phoenix/Elixir best practices
- ✅ Requires minimal code changes
- ✅ Provides clear path for future enhancements
- ✅ Maintains separation between development and production deployment

**Estimated Implementation Time**: 1-2 hours
**Risk Level**: Low (all seeds already idempotent)
**Testing Required**: Moderate (verify seed execution and data integrity)
