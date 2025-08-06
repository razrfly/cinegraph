# Test the import system with a small dataset
IO.puts("=== Testing Import System ===\n")

# 1. First check and set TMDB total
IO.puts("1. Updating TMDB total count...")

case Cinegraph.Imports.TMDbImporter.update_tmdb_total() do
  {:ok, total} ->
    IO.puts("   TMDB Total: #{total} movies")

  {:error, reason} ->
    IO.puts("   ❌ Failed to update TMDB total: #{inspect(reason)}")
    System.halt(1)
end

# 2. Check initial progress
IO.puts("\n2. Initial progress:")
progress = Cinegraph.Imports.TMDbImporter.get_progress()
IO.inspect(progress, pretty: true)

# 3. Start import
IO.puts("\n3. Starting import...")

case Cinegraph.Imports.TMDbImporter.start_full_import() do
  {:ok, info} ->
    IO.puts("   Started from page: #{info.starting_page}")

  {:error, reason} ->
    IO.puts("   ❌ Failed to start import: #{inspect(reason)}")
    System.halt(1)
end

# 4. Wait a moment for the first job to process
IO.puts("\n4. Waiting 5 seconds for first job to process...")
Process.sleep(5000)

# 5. Check if any jobs were created
import Ecto.Query
alias Cinegraph.Repo

job_counts =
  Repo.all(
    from j in Oban.Job,
      group_by: [j.queue, j.state],
      select: {j.queue, j.state, count(j.id)}
  )

IO.puts("\n5. Job status:")

Enum.each(job_counts, fn {queue, state, count} ->
  IO.puts("   #{queue} - #{state}: #{count}")
end)

# 6. Check updated progress
IO.puts("\n6. Updated progress:")
new_progress = Cinegraph.Imports.TMDbImporter.get_progress()
IO.inspect(new_progress, pretty: true)

# 7. Check if any movies were imported
movie_count = Repo.aggregate(Cinegraph.Movies.Movie, :count)
IO.puts("\n7. Movies imported so far: #{movie_count}")

# 8. Check last page processed from state
last_page = Cinegraph.Imports.ImportState.get("last_page_processed")
IO.puts("\n8. Last page processed (from state): #{inspect(last_page)}")
