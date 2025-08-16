#!/usr/bin/env elixir
# Script to clean up duplicate canonical entries

alias Cinegraph.Repo
alias Cinegraph.Movies.Movie
import Ecto.Query

IO.puts("=== Cleaning Up Canonical Duplicates ===\n")

# For each canonical source, find and fix duplicates
canonical_sources = ["1001_movies", "criterion", "national_film_registry", "cannes_winners", "sight_sound_critics_2022"]

Enum.each(canonical_sources, fn source_key ->
  IO.puts("\nProcessing #{source_key}...")
  
  # Find all positions that have duplicates
  duplicate_positions_query = """
  SELECT 
    canonical_sources->'#{source_key}'->>'list_position' as position,
    COUNT(*) as count,
    array_agg(id) as movie_ids
  FROM movies 
  WHERE canonical_sources ? '#{source_key}'
  GROUP BY canonical_sources->'#{source_key}'->>'list_position'
  HAVING COUNT(*) > 1
  ORDER BY (canonical_sources->'#{source_key}'->>'list_position')::int
  """
  
  case Repo.query(duplicate_positions_query) do
    {:ok, %{rows: rows}} when length(rows) > 0 ->
      IO.puts("Found #{length(rows)} positions with duplicates")
      
      Enum.each(rows, fn [position, count, movie_ids] ->
        IO.puts("\n  Position #{position}: #{count} duplicates")
        
        # Get the movies
        movies = Repo.all(from m in Movie, where: m.id in ^movie_ids)
        
        # Sort by various criteria to pick the best one
        # Prefer: has more data, was created first, has higher vote count
        sorted_movies = movies
        |> Enum.sort_by(fn movie ->
          {
            # Prefer movies with more complete data
            -(if movie.runtime, do: 1, else: 0),
            -(if movie.budget && movie.budget > 0, do: 1, else: 0),
            -(movie.vote_count || 0),
            # Earlier creation date
            movie.inserted_at
          }
        end)
        
        [keep_movie | remove_movies] = sorted_movies
        
        IO.puts("  Keeping: #{keep_movie.title} (ID: #{keep_movie.id}, votes: #{keep_movie.vote_count})")
        
        # Remove the canonical source from the duplicate movies
        Repo.transaction(fn ->
          Enum.each(remove_movies, fn movie ->
            IO.puts("  Removing from: #{movie.title} (ID: #{movie.id})")
            
            updated_sources = Map.delete(movie.canonical_sources || %{}, source_key)
            
            movie
            |> Movie.changeset(%{canonical_sources: updated_sources})
            |> Repo.update!()
          end)
        end)
      end)
      
      IO.puts("\nCleaned up #{length(rows)} duplicate positions for #{source_key}")
      
    {:ok, %{rows: []}} ->
      IO.puts("No duplicates found for #{source_key}")
      
    {:error, error} ->
      IO.puts("Error checking duplicates for #{source_key}: #{inspect(error)}")
  end
end)

# Final statistics
IO.puts("\n\n=== Final Statistics ===")

Enum.each(canonical_sources, fn source_key ->
  {:ok, %{rows: [[count]]}} = Repo.query(
    "SELECT COUNT(*) FROM movies WHERE canonical_sources ? $1",
    [source_key]
  )
  
  IO.puts("#{source_key}: #{count} movies")
end)

IO.puts("\nCleanup complete!")