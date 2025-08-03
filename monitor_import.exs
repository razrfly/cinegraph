# Import monitoring script
# Run this periodically to check import progress

import Ecto.Query
alias Cinegraph.Repo

defmodule ImportMonitor do
  def check_status do
    progress = Cinegraph.Imports.TMDbImporter.get_progress()
    
    # Calculate rates
    movies_per_page = 20
    pages_processed = String.to_integer(progress.last_page_processed || "0")
    minutes_elapsed = if pages_processed > 0, do: pages_processed * 0.7, else: 1  # ~40-45 seconds per page
    import_rate = if minutes_elapsed > 0, do: Float.round(progress.our_total_movies / minutes_elapsed, 2), else: 0
    
    # Job stats
    job_stats = Repo.all(
      from j in Oban.Job,
      where: j.state in ["available", "executing", "scheduled"],
      group_by: j.queue,
      select: {j.queue, count(j.id)}
    )
    
    # Failed jobs
    failed_count = Repo.aggregate(
      from(j in Oban.Job, where: j.state in ["discarded", "cancelled"]),
      :count
    )
    
    # Data quality
    with_omdb = Repo.aggregate(
      from(m in Cinegraph.Movies.Movie, where: not is_nil(m.omdb_data)),
      :count
    )
    
    with_genres = Repo.one(
      from mg in "movie_genres",
      select: count(mg.movie_id, :distinct)
    )
    
    with_credits = Repo.one(
      from mc in "movie_credits",
      select: count(mc.movie_id, :distinct)
    )
    
    IO.puts("\n=== IMPORT MONITOR - #{DateTime.utc_now() |> DateTime.to_string()} ===")
    IO.puts("\nPROGRESS:")
    IO.puts("  Movies: #{progress.our_total_movies} / #{progress.tmdb_total_movies} (#{progress.completion_percentage}%)")
    IO.puts("  Pages: #{progress.last_page_processed} / ~51,749")
    IO.puts("  Rate: ~#{import_rate} movies/minute")
    IO.puts("  ETA for 10k: ~#{Float.round((10_000 - progress.our_total_movies) / max(import_rate, 1), 1)} minutes")
    
    IO.puts("\nQUEUES:")
    Enum.each(job_stats, fn {queue, count} ->
      IO.puts("  #{queue}: #{count} pending")
    end)
    IO.puts("  Failed jobs: #{failed_count}")
    
    IO.puts("\nDATA QUALITY:")
    IO.puts("  With OMDb data: #{with_omdb} (#{Float.round(with_omdb / max(progress.our_total_movies, 1) * 100, 1)}%)")
    IO.puts("  With genres: #{with_genres}")
    IO.puts("  With credits: #{with_credits}")
    
    # Check for issues
    if failed_count > progress.our_total_movies * 0.01 do
      IO.puts("\n⚠️  WARNING: High failure rate (>1%)")
    end
    
    if import_rate < 10 and progress.our_total_movies > 100 do
      IO.puts("\n⚠️  WARNING: Import rate is slow")
    end
    
    IO.puts("\n" <> String.duplicate("=", 60))
  end
end

# Run the monitor
ImportMonitor.check_status()