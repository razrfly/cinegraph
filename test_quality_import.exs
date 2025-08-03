# Test import with quality filters
import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Imports.TMDbImporter

IO.puts("=== TESTING IMPORT WITH QUALITY FILTERS ===\n")

# Update TMDB total
case TMDbImporter.update_tmdb_total() do
  {:ok, total} ->
    IO.puts("TMDB Total: #{total} movies")
  error ->
    IO.puts("Failed to update TMDB total: #{inspect(error)}")
end

# Import 5 pages (approximately 100 movies)
IO.puts("\nImporting 5 pages to test quality filters...")
case TMDbImporter.queue_pages(1, 5) do
  {:ok, count} ->
    IO.puts("Queued #{count} discovery jobs")
  error ->
    IO.puts("Failed to queue pages: #{inspect(error)}")
end

# Wait for imports to process
IO.puts("\nWaiting 30 seconds for imports to process...")
Process.sleep(30_000)

# Check results
IO.puts("\n=== IMPORT RESULTS ===")

# Movie counts
full_imports = Repo.one(from m in Cinegraph.Movies.Movie, where: m.import_status == "full", select: count(m.id))
soft_imports = Repo.one(from m in Cinegraph.Movies.Movie, where: m.import_status == "soft", select: count(m.id))
total_movies = full_imports + soft_imports

IO.puts("Total movies: #{total_movies}")
IO.puts("  Full imports: #{full_imports}")
IO.puts("  Soft imports: #{soft_imports}")

# People count
people_count = Repo.aggregate(Cinegraph.Movies.Person, :count)
people_with_photos = Repo.one(from p in Cinegraph.Movies.Person, where: not is_nil(p.profile_path), select: count(p.id))
IO.puts("\nPeople imported: #{people_count}")
IO.puts("  With photos: #{people_with_photos} (#{Float.round(people_with_photos/max(people_count, 1)*100, 1)}%)")

# Check skipped imports
skipped_count = Repo.aggregate(Cinegraph.Imports.SkippedImport, :count)
IO.puts("\nSkipped imports tracked: #{skipped_count}")

# Sample some soft imports
if soft_imports > 0 do
  IO.puts("\n=== SAMPLE SOFT IMPORTS ===")
  soft_movies = Repo.all(
    from m in Cinegraph.Movies.Movie,
    where: m.import_status == "soft",
    limit: 5,
    select: %{title: m.title, popularity: m.popularity, vote_count: m.vote_count, has_poster: not is_nil(m.poster_path)}
  )
  
  Enum.each(soft_movies, fn movie ->
    IO.puts("  #{movie.title}: pop=#{movie.popularity}, votes=#{movie.vote_count}, poster=#{movie.has_poster}")
  end)
end

# Check collaborations
collab_count = Repo.aggregate(Cinegraph.Collaborations.Collaboration, :count)
IO.puts("\nCollaborations: #{collab_count}")

# Check Oban status
job_stats = Repo.all(
  from j in Oban.Job,
  group_by: [j.queue, j.state],
  select: {j.queue, j.state, count(j.id)}
)

IO.puts("\n=== JOB STATUS ===")
Enum.each(job_stats, fn {queue, state, count} ->
  IO.puts("  #{queue} - #{state}: #{count}")
end)