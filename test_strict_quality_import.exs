# Test import with stricter quality filters
import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Imports.TMDbImporter

IO.puts("=== TESTING IMPORT WITH STRICTER QUALITY FILTERS ===\n")
IO.puts("Movie criteria:")
IO.puts("  - Must have poster")
IO.puts("  - Must have ≥25 votes")
IO.puts("  - Must have ≥5.0 popularity") 
IO.puts("  - Must have release date")
IO.puts("\nPerson criteria:")
IO.puts("  - Must have ≥0.5 popularity")
IO.puts("  - Key roles need profile OR popularity")
IO.puts("  - Other roles need profile AND popularity\n")

# Update TMDB total
case TMDbImporter.update_tmdb_total() do
  {:ok, total} ->
    IO.puts("\nTMDB Total: #{total} movies")
  error ->
    IO.puts("Failed to update TMDB total: #{inspect(error)}")
end

# Import 10 pages to get a better sample
IO.puts("\nImporting 10 pages to test stricter quality filters...")
case TMDbImporter.queue_pages(1, 10) do
  {:ok, count} ->
    IO.puts("Queued #{count} discovery jobs")
  error ->
    IO.puts("Failed to queue pages: #{inspect(error)}")
end

# Wait for imports to process
IO.puts("\nWaiting 60 seconds for imports to process...")
Process.sleep(60_000)

# Check results
IO.puts("\n=== IMPORT RESULTS WITH STRICTER FILTERS ===")

# Movie counts
full_imports = Repo.one(from m in Cinegraph.Movies.Movie, where: m.import_status == "full", select: count(m.id))
soft_imports = Repo.one(from m in Cinegraph.Movies.Movie, where: m.import_status == "soft", select: count(m.id))
total_movies = full_imports + soft_imports

IO.puts("\nTotal movies: #{total_movies}")
IO.puts("  Full imports: #{full_imports} (#{Float.round(full_imports/max(total_movies, 1)*100, 1)}%)")
IO.puts("  Soft imports: #{soft_imports} (#{Float.round(soft_imports/max(total_movies, 1)*100, 1)}%)")

# People count
people_count = Repo.aggregate(Cinegraph.Movies.Person, :count)
people_with_photos = Repo.one(from p in Cinegraph.Movies.Person, where: not is_nil(p.profile_path), select: count(p.id))
IO.puts("\nPeople imported: #{people_count}")
IO.puts("  With photos: #{people_with_photos} (#{Float.round(people_with_photos/max(people_count, 1)*100, 1)}%)")

# Check collaborations
collab_count = Repo.aggregate(Cinegraph.Collaborations.Collaboration, :count)
IO.puts("\nCollaborations: #{collab_count}")

# Sample soft imports
if soft_imports > 0 do
  IO.puts("\n=== SAMPLE SOFT IMPORTS ===")
  soft_movies = Repo.all(
    from m in Cinegraph.Movies.Movie,
    where: m.import_status == "soft",
    limit: 10,
    order_by: [desc: m.popularity],
    select: %{title: m.title, popularity: m.popularity, vote_count: m.vote_count, has_poster: not is_nil(m.poster_path)}
  )
  
  Enum.each(soft_movies, fn movie ->
    IO.puts("  #{movie.title}: pop=#{movie.popularity}, votes=#{movie.vote_count}, poster=#{movie.has_poster}")
  end)
end

# Sample full imports
IO.puts("\n=== SAMPLE FULL IMPORTS ===")
full_movies = Repo.all(
  from m in Cinegraph.Movies.Movie,
  where: m.import_status == "full",
  limit: 5,
  order_by: [desc: m.popularity],
  select: %{title: m.title, popularity: m.popularity, vote_count: m.vote_count}
)

Enum.each(full_movies, fn movie ->
  IO.puts("  #{movie.title}: pop=#{movie.popularity}, votes=#{movie.vote_count}")
end)

# Quality analysis
IO.puts("\n=== QUALITY ANALYSIS ===")
if full_imports > 0 do
  avg_pop = Repo.one(from m in Cinegraph.Movies.Movie, where: m.import_status == "full", select: avg(m.popularity))
  avg_votes = Repo.one(from m in Cinegraph.Movies.Movie, where: m.import_status == "full", select: avg(m.vote_count))
  
  IO.puts("Full imports average popularity: #{Float.round(avg_pop || 0, 2)}")
  IO.puts("Full imports average vote count: #{Float.round(avg_votes || 0, 0)}")
end

# Check skipped imports
skipped_count = Repo.aggregate(Cinegraph.Imports.SkippedImport, :count)
IO.puts("\nSkipped imports tracked: #{skipped_count}")