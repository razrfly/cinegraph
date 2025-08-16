defmodule UpdateMissingOMDb do
  alias Cinegraph.MovieImporter
  alias Cinegraph.Movies
  alias Cinegraph.ApiProcessors
  import Ecto.Query
  require Logger
  
  def run do
    IO.puts("\n🔄 UPDATING MISSING OMDb DATA\n")
    IO.puts(String.duplicate("=", 60))
    
    # First, get a summary of current coverage
    summary = MovieImporter.get_api_coverage_summary()
    
    IO.puts("Current API Coverage:")
    IO.puts("  Total movies: #{summary.total_movies}")
    Enum.each(summary.coverage, fn {api, data} ->
      IO.puts("  #{String.upcase(api)}: #{data.count} movies (#{data.percentage}%)")
    end)
    
    # Find movies missing OMDb data
    missing_omdb = find_movies_missing_omdb_data()
    IO.puts("\nMovies missing OMDb data: #{length(missing_omdb)}")
    
    if length(missing_omdb) > 0 do
      IO.puts("\nSample of movies to update:")
      missing_omdb
      |> Enum.take(10)
      |> Enum.each(fn movie ->
        IO.puts("  - #{movie.title} (IMDb: #{movie.imdb_id || "N/A"})")
      end)
      
      if length(missing_omdb) > 10 do
        IO.puts("  ... and #{length(missing_omdb) - 10} more")
      end
      
      # Ask for confirmation
      IO.puts("\nThis will make #{length(missing_omdb)} API calls to OMDb.")
      IO.puts("With 1 second delay between calls, this will take approximately #{div(length(missing_omdb), 60)} minutes.")
      
      if confirm_update?() do
        process_missing_movies(missing_omdb)
      else
        IO.puts("\nUpdate cancelled.")
      end
    else
      IO.puts("\n✅ All movies with IMDb IDs already have OMDb data!")
    end
  end
  
  defp find_movies_missing_omdb_data do
    Cinegraph.Repo.all(
      from m in Cinegraph.Movies.Movie,
      where: not is_nil(m.imdb_id) and is_nil(m.omdb_data),
      order_by: [desc: m.popularity],
      select: m
    )
  end
  
  defp confirm_update? do
    IO.gets("\nProceed with update? (y/n): ")
    |> String.trim()
    |> String.downcase()
    == "y"
  end
  
  defp process_missing_movies(movies) do
    IO.puts("\n🚀 Starting OMDb updates...\n")
    
    start_time = System.monotonic_time(:second)
    total = length(movies)
    
    results = movies
    |> Enum.with_index(1)
    |> Enum.map(fn {movie, index} ->
      IO.write("\r[#{index}/#{total}] Processing #{movie.title}...")
      
      result = MovieImporter.process_movie_api(movie.id, "omdb", queue: false)
      
      # Rate limiting is handled by the processor (1 second delay)
      
      case result do
        {:ok, updated_movie} ->
          if updated_movie.omdb_data do
            IO.write(" ✅")
            :success
          else
            IO.write(" ⚠️  (No data)")
            :no_data
          end
        {:error, reason} ->
          IO.write(" ❌ (#{inspect(reason)})")
          :error
      end
    end)
    
    elapsed = System.monotonic_time(:second) - start_time
    
    # Print summary
    IO.puts("\n\n" <> String.duplicate("=", 60))
    IO.puts("Update Complete! Time elapsed: #{format_duration(elapsed)}")
    IO.puts(String.duplicate("=", 60))
    
    success_count = Enum.count(results, & &1 == :success)
    no_data_count = Enum.count(results, & &1 == :no_data)
    error_count = Enum.count(results, & &1 == :error)
    
    IO.puts("\nResults:")
    IO.puts("  ✅ Successfully updated: #{success_count}")
    IO.puts("  ⚠️  No data available: #{no_data_count}")
    IO.puts("  ❌ Errors: #{error_count}")
    IO.puts("  📊 Total processed: #{total}")
    
    # Show new coverage
    IO.puts("\nNew API Coverage:")
    new_summary = MovieImporter.get_api_coverage_summary()
    Enum.each(new_summary.coverage, fn {api, data} ->
      IO.puts("  #{String.upcase(api)}: #{data.count} movies (#{data.percentage}%)")
    end)
  end
  
  defp format_duration(seconds) when seconds < 60 do
    "#{seconds} seconds"
  end
  defp format_duration(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)
    "#{minutes} minutes #{remaining_seconds} seconds"
  end
end

# Check if we have API keys
case System.get_env("OMDB_API_KEY") do
  nil ->
    IO.puts("❌ Error: OMDB_API_KEY environment variable not set")
    IO.puts("\nPlease set your OMDb API key:")
    IO.puts("  export OMDB_API_KEY=your_key_here")
    IO.puts("\nOr load from .env file:")
    IO.puts("  source .env")
  _ ->
    UpdateMissingOMDb.run()
end