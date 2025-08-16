#!/usr/bin/env elixir
# Script to audit and fix missing canonical sources

alias Cinegraph.Repo
alias Cinegraph.Movies.Movie
import Ecto.Query

IO.puts("=== Canonical Sources Audit ===\n")

# Get all canonical lists
canonical_lists = [
  {"1001_movies", "1001 Movies You Must See Before You Die"},
  {"criterion", "The Criterion Collection"},
  {"national_film_registry", "National Film Registry"},
  {"cannes_winners", "Cannes Film Festival Award Winners"},
  {"sight_sound_critics_2022", "BFI's Sight & Sound Critics' Top 100"}
]

# For each list, check what was processed vs what's in the database
Enum.each(canonical_lists, fn {source_key, list_name} ->
  IO.puts("\n#{list_name} (#{source_key})")
  IO.puts(String.duplicate("-", 60))
  
  # Get counts from Oban metadata
  oban_query = """
  SELECT 
    SUM(CAST(meta->>'movies_found' AS INTEGER)) as total_found,
    SUM(CAST(meta->>'movies_queued' AS INTEGER)) as total_queued,
    SUM(CAST(meta->>'movies_updated' AS INTEGER)) as total_updated
  FROM oban_jobs 
  WHERE worker = 'Cinegraph.Workers.CanonicalPageWorker'
  AND args->>'list_key' = $1
  AND state = 'completed'
  """
  
  case Repo.query(oban_query, [source_key]) do
    {:ok, %{rows: [[found, queued, updated]]}} ->
      # Get actual count in database
      db_count = Repo.one(
        from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, ^source_key),
        select: count(m.id)
      )
      
      # Calculate missing
      expected = (queued || 0) + (updated || 0)
      missing = expected - db_count
      
      IO.puts("  Found in scrape: #{found || 0}")
      IO.puts("  Queued for creation: #{queued || 0}")
      IO.puts("  Updated existing: #{updated || 0}")
      IO.puts("  Expected total: #{expected}")
      IO.puts("  Actually in DB: #{db_count}")
      
      if missing > 0 do
        IO.puts("  ⚠️  MISSING: #{missing} movies")
        
        # Try to find movies that might be missing the canonical source
        # by checking TMDbDetailsWorker jobs
        tmdb_query = """
        SELECT COUNT(DISTINCT args->>'imdb_id')
        FROM oban_jobs
        WHERE worker = 'Cinegraph.Workers.TMDbDetailsWorker'
        AND args->>'source' = 'canonical_import'
        AND args->'canonical_sources' ? $1
        AND state = 'completed'
        """
        
        case Repo.query(tmdb_query, [source_key]) do
          {:ok, %{rows: [[processed_count]]}} ->
            IO.puts("  TMDb workers processed: #{processed_count || 0}")
            
            if processed_count && processed_count > db_count do
              IO.puts("  🔍 Some movies were processed but canonical source not saved!")
            end
          _ -> nil
        end
      else
        IO.puts("  ✅ All expected movies are in the database")
      end
      
    {:error, error} ->
      IO.puts("  Error querying Oban data: #{inspect(error)}")
  end
end)

IO.puts("\n\n=== Attempting to Fix Missing Canonical Sources ===\n")

# Find all completed TMDbDetailsWorker jobs with canonical sources
fix_query = """
SELECT 
  j.id,
  j.args->>'imdb_id' as imdb_id,
  j.args->'canonical_sources' as canonical_sources,
  j.meta->>'movie_id' as movie_id
FROM oban_jobs j
WHERE j.worker = 'Cinegraph.Workers.TMDbDetailsWorker'
AND j.args->>'source' = 'canonical_import'
AND j.args->'canonical_sources' IS NOT NULL
AND j.state = 'completed'
"""

case Repo.query(fix_query, []) do
  {:ok, %{rows: rows}} ->
    IO.puts("Found #{length(rows)} completed canonical import jobs")
    
    fixed_count = 0
    
    fixed_count = Enum.reduce(rows, 0, fn [job_id, imdb_id, canonical_sources_json, movie_id], acc ->
      # Parse the canonical sources - it might already be a map
      canonical_sources = if is_binary(canonical_sources_json) do
        Jason.decode!(canonical_sources_json)
      else
        canonical_sources_json
      end
      
      # Try to find the movie
      movie = cond do
        movie_id -> Repo.get(Movie, movie_id)
        imdb_id -> Repo.get_by(Movie, imdb_id: imdb_id)
        true -> nil
      end
      
      if movie do
        current_sources = movie.canonical_sources || %{}
        
        # Check each canonical source
        needs_update = Enum.any?(canonical_sources, fn {source_key, _data} ->
          not Map.has_key?(current_sources, source_key)
        end)
        
        if needs_update do
          # Merge in the missing sources
          updated_sources = Map.merge(current_sources, canonical_sources)
          
          IO.puts("\nFixing movie: #{movie.title} (ID: #{movie.id})")
          IO.puts("  Current sources: #{inspect(Map.keys(current_sources))}")
          IO.puts("  Adding sources: #{inspect(Map.keys(canonical_sources))}")
          
          case movie
               |> Movie.changeset(%{canonical_sources: updated_sources})
               |> Repo.update() do
            {:ok, _updated} ->
              IO.puts("  ✅ Fixed!")
              acc + 1
              
            {:error, changeset} ->
              IO.puts("  ❌ Failed: #{inspect(changeset.errors)}")
              acc
          end
        else
          acc
        end
      else
        IO.puts("\n⚠️  Could not find movie for job #{job_id} (IMDb: #{imdb_id})")
        acc
      end
    end)
    
    IO.puts("\n\nFixed #{fixed_count} movies with missing canonical sources")
    
  {:error, error} ->
    IO.puts("Error querying jobs: #{inspect(error)}")
end

IO.puts("\n\n=== Final Summary ===\n")

# Show final counts
Enum.each(canonical_lists, fn {source_key, list_name} ->
  count = Repo.one(
    from m in Movie,
    where: fragment("? \\? ?", m.canonical_sources, ^source_key),
    select: count(m.id)
  )
  
  IO.puts("#{list_name}: #{count} movies")
end)