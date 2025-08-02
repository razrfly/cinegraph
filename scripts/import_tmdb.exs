#!/usr/bin/env elixir
# Script to import movies from TMDb using the new Oban-based system
# Run with: ./scripts/run_with_env.sh mix run scripts/import_tmdb.exs

require Logger

# Parse command line arguments
{opts, _, _} = OptionParser.parse(System.argv(),
  switches: [
    type: :string,
    pages: :integer,
    decade: :integer,
    year: :integer,
    start_date: :string,
    end_date: :string,
    min_votes: :integer,
    help: :boolean
  ],
  aliases: [h: :help]
)

if opts[:help] do
  IO.puts("""
  TMDb Import Script - Import movies using Oban job queuing system

  Usage: mix run scripts/import_tmdb.exs [options]

  Options:
    --type TYPE         Type of import: full, daily, decade, popular (default: popular)
    --pages N           Max pages to import (default: varies by type)
    --decade N          Decade to import (e.g., 1980 for 1980s)
    --year N            Specific year to import
    --start-date DATE   Start date for filtering (YYYY-MM-DD)
    --end-date DATE     End date for filtering (YYYY-MM-DD)
    --min-votes N       Minimum vote count for popular imports (default: 100)
    --help, -h          Show this help message

  Examples:
    # Import popular movies (default)
    mix run scripts/import_tmdb.exs

    # Import 10 pages of popular movies
    mix run scripts/import_tmdb.exs --type popular --pages 10

    # Import movies from the 1990s
    mix run scripts/import_tmdb.exs --type decade --decade 1990

    # Daily update (last 7 days)
    mix run scripts/import_tmdb.exs --type daily

    # Full import with date range
    mix run scripts/import_tmdb.exs --type full --start-date 2020-01-01 --end-date 2023-12-31
  """)
  System.halt(0)
end

# Verify API key is available
case System.get_env("TMDB_API_KEY") do
  nil ->
    Logger.error("TMDB_API_KEY not set!")
    Logger.error("")
    Logger.error("Please ensure you're running this script with environment variables loaded:")
    Logger.error("  1. Make sure .env file exists with TMDB_API_KEY=your-key")
    Logger.error("  2. Run this script using: ./scripts/run_with_env.sh mix run scripts/import_tmdb.exs")
    Logger.error("  OR manually: source .env && mix run scripts/import_tmdb.exs")
    System.halt(1)
    
  api_key ->
    Logger.info("TMDB API key found: #{String.slice(api_key, 0..5)}...")
end

# Determine import type
import_type = opts[:type] || "popular"

# Start the import based on type
{:ok, progress} = case import_type do
  "full" ->
    Logger.info("Starting full TMDb import...")
    import_opts = []
    import_opts = if opts[:pages], do: Keyword.put(import_opts, :max_pages, opts[:pages]), else: import_opts
    import_opts = if opts[:year], do: Keyword.put(import_opts, :year, opts[:year]), else: import_opts
    import_opts = if opts[:start_date], do: Keyword.put(import_opts, :start_date, opts[:start_date]), else: import_opts
    import_opts = if opts[:end_date], do: Keyword.put(import_opts, :end_date, opts[:end_date]), else: import_opts
    
    Cinegraph.Imports.TMDbImporter.start_full_import(import_opts)
    
  "daily" ->
    Logger.info("Starting daily update import...")
    Cinegraph.Imports.TMDbImporter.start_daily_update()
    
  "decade" ->
    decade = opts[:decade] || raise ArgumentError, "--decade is required for decade imports"
    Logger.info("Starting import for the #{decade}s...")
    Cinegraph.Imports.TMDbImporter.start_decade_import(decade)
    
  "popular" ->
    Logger.info("Starting popular movies import...")
    import_opts = []
    import_opts = if opts[:pages], do: Keyword.put(import_opts, :max_pages, opts[:pages]), else: import_opts
    import_opts = if opts[:min_votes], do: Keyword.put(import_opts, :min_vote_count, opts[:min_votes]), else: import_opts
    
    Cinegraph.Imports.TMDbImporter.start_popular_import(import_opts)
    
  _ ->
    Logger.error("Unknown import type: #{import_type}")
    Logger.error("Valid types: full, daily, decade, popular")
    System.halt(1)
end

Logger.info("""
✅ Import started successfully!
   Progress ID: #{progress.id}
   Type: #{progress.import_type}
   Status: #{progress.status}

📊 Monitor progress at:
   - Import Dashboard: http://localhost:4000/imports
   - Oban Dashboard: http://localhost:4000/oban

Jobs will be processed automatically by Oban workers.
""")

# Show initial status
statuses = Cinegraph.Imports.TMDbImporter.get_import_status()
if length(statuses) > 0 do
  Logger.info("\nCurrent imports:")
  Enum.each(statuses, fn status ->
    Logger.info("""
      - #{status.type} (ID: #{status.id})
        Status: #{status.status}
        Progress: Page #{status.current_page || 0}/#{status.total_pages || "?"}
        Movies: #{status.movies_found} found, #{status.movies_imported} imported
        Rate: #{status.rate} movies/min
    """)
  end)
end