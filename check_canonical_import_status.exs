# Script to check the status of canonical imports
import Ecto.Query

IO.puts("\n=== Canonical Import Status ===\n")

# Count movies by canonical source
canonical_counts = 
  from(m in Cinegraph.Movies.Movie,
    where: not is_nil(m.canonical_sources),
    select: {fragment("jsonb_object_keys(?)", m.canonical_sources), count(m.id)},
    group_by: fragment("jsonb_object_keys(?)", m.canonical_sources)
  )
  |> Cinegraph.Repo.all()
  |> Enum.into(%{})

IO.puts("Movies by canonical source:")
Enum.each(canonical_counts, fn {source, count} ->
  IO.puts("  #{source}: #{count} movies")
end)

# Count failed lookups
failed_lookups = 
  from(f in Cinegraph.Movies.FailedImdbLookup,
    group_by: [f.source_key, f.reason],
    select: {f.source_key, f.reason, count(f.id)}
  )
  |> Cinegraph.Repo.all()

IO.puts("\nFailed IMDb lookups:")
Enum.each(failed_lookups, fn {source_key, reason, count} ->
  IO.puts("  #{source_key || "unknown"} - #{reason}: #{count} movies")
end)

# Show some examples of failed lookups
examples = 
  from(f in Cinegraph.Movies.FailedImdbLookup,
    limit: 5,
    order_by: [desc: f.inserted_at]
  )
  |> Cinegraph.Repo.all()

IO.puts("\nRecent failed lookups:")
Enum.each(examples, fn failed ->
  IO.puts("  #{failed.imdb_id}: #{failed.title || "Unknown"} (#{failed.year || "N/A"}) - #{failed.source_key}")
end)

# Check discarded Oban jobs
discarded_count = 
  from(j in Oban.Job,
    where: j.worker == "Cinegraph.Workers.TMDbDetailsWorker" and
           j.state == "discarded" and
           fragment("? ->> ?", j.args, "source") == "canonical_import",
    select: count(j.id)
  )
  |> Cinegraph.Repo.one()

IO.puts("\nDiscarded TMDb lookup jobs: #{discarded_count}")

# Summary
total_canonical = canonical_counts |> Map.values() |> Enum.sum()
total_failed = failed_lookups |> Enum.map(fn {_, _, count} -> count end) |> Enum.sum()

IO.puts("\n=== Summary ===")
IO.puts("Total canonical movies imported: #{total_canonical}")
IO.puts("Total failed lookups: #{total_failed}")
total = total_canonical + total_failed
success_rate = if total > 0, do: Float.round(total_canonical / total * 100, 2), else: 0.0
IO.puts("Success rate: #{success_rate}%")