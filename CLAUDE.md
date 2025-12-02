# Cinegraph - Essential Context for Claude

## Project Overview
Cinegraph is an Elixir/Phoenix LiveView application for movie discovery, tracking film industry relationships, and managing awards data.

## ⚠️ IMPORTANT: Version Control Policy
**DO NOT USE GIT COMMANDS** - The user manages all git operations themselves. Never run `git add`, `git commit`, `git push`, or any other git commands unless explicitly instructed to do so.

## Tech Stack
- **Backend**: Elixir 1.18, Phoenix 1.7.17, LiveView
- **Database**: PostgreSQL (local development via Postgres.app)
- **External APIs**: TMDb, OMDb, IMDb scraping
- **Background Jobs**: Oban
- **Styling**: Tailwind CSS

## Key Modules

### Core Contexts
- `Cinegraph.Movies` - Movie data management
- `Cinegraph.People` - Actor/director management  
- `Cinegraph.Collaborations` - Relationship tracking
- `Cinegraph.Cultural` - Awards/festivals
- `Cinegraph.Metrics` - Analytics & metrics
- `Cinegraph.Events` - Festival event management

### LiveView Components
- `ImportDashboardLive` - Import management UI
- `MovieLive.Show` - Movie details
- `PersonLive.Show` - Person details
- `SixDegreesLive` - Collaboration paths
- `CollaborationLive` - Collaboration explorer

### Background Workers
- `TMDbDetailsWorker` - Fetch movie details
- `CanonicalImportOrchestrator` - Import canonical lists
- `UnifiedFestivalWorker` - Festival data import
- `FestivalDiscoveryWorker` - Process festival nominations

## Database Schema Highlights
- `movies` - Core movie data with JSONB fields for TMDb/OMDb data
- `people` - Cast and crew
- `collaborations` - Person-to-person collaboration tracking
- `festival_*` tables - Festival/award tracking
- `external_metrics` - External ratings/metrics

## Common Commands
```bash
# Development
mix phx.server              # Start server
mix test                     # Run tests
iex -S mix phx.server       # Interactive console with server

# Database
mix ecto.reset              # Reset database
mix ecto.migrate            # Run migrations

# Imports (requires API keys in env)
mix import_movies --pages 5 # Import movies from TMDb
```

## Environment Variables
- `TMDB_API_KEY` - TMDb API access
- `OMDB_API_KEY` - OMDb API access
- `DATABASE_URL` - Database connection (production)
- `ZYTE_API_KEY` - Web scraping service

## Project Structure
```
lib/
├── cinegraph/        # Business logic contexts
├── cinegraph_web/    # Web layer
│   ├── live/         # LiveView components
│   └── components/   # Reusable components
priv/
├── repo/
│   ├── migrations/   # Database migrations
│   └── seeds.exs     # Seed data
```

## Development Notes
- Always run `mix format` before committing
- Use Oban for background jobs, not manual async tasks
- Prefer Ecto queries over raw SQL
- LiveView components handle their own state

## Performance Considerations
- Large LiveView files (>300 lines) should be refactored
- Use database indexes for frequent queries
- Cache expensive API calls
- Batch database operations when possible