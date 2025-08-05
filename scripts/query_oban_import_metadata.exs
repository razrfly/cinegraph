# Query Oban job metadata for import tracking
import Ecto.Query
alias Cinegraph.Repo

IO.puts("=== OBAN IMPORT METADATA QUERIES ===\n")

# 1. Failed IMDb lookups (previously in failed_imdb_lookups table)
IO.puts("1. Failed IMDb Lookups:")
IO.puts(String.duplicate("-", 50))

failed_lookups = Repo.all(
  from j in "oban_jobs",
  where: j.worker == "Elixir.Cinegraph.Workers.TMDbDetailsWorker",
  where: j.state in ["discarded", "retryable"],
  where: fragment("? ->> 'failure_reason' = ?", j.meta, "no_tmdb_match"),
  select: %{
    imdb_id: fragment("? ->> 'imdb_id'", j.meta),
    title: fragment("? ->> 'title'", j.meta),
    source: fragment("? ->> 'source'", j.meta),
    inserted_at: j.inserted_at
  },
  order_by: [desc: j.inserted_at],
  limit: 10
)

Enum.each(failed_lookups, fn lookup ->
  IO.puts("  #{lookup.title} (#{lookup.imdb_id}) - Source: #{lookup.source}")
end)

IO.puts("\nTotal failed lookups: #{length(failed_lookups)}")

# 2. Soft imports (previously in skipped_imports table)
IO.puts("\n2. Soft Imports (Quality Criteria Failed):")
IO.puts(String.duplicate("-", 50))

soft_imports = Repo.all(
  from j in "oban_jobs",
  where: j.worker == "Elixir.Cinegraph.Workers.TMDbDetailsWorker",
  where: fragment("? ->> 'import_type' = ?", j.meta, "soft"),
  select: %{
    movie_title: fragment("? ->> 'movie_title'", j.meta),
    tmdb_id: fragment("? ->> 'tmdb_id'", j.meta),
    criteria_failed: fragment("? -> 'quality_criteria_failed'", j.meta),
    inserted_at: j.inserted_at
  },
  order_by: [desc: j.inserted_at],
  limit: 10
)

Enum.each(soft_imports, fn import ->
  IO.puts("  #{import.movie_title} (TMDb: #{import.tmdb_id})")
  if import.criteria_failed do
    IO.puts("    Failed criteria: #{inspect(import.criteria_failed)}")
  end
end)

# 3. Summary statistics
IO.puts("\n3. Import Summary:")
IO.puts(String.duplicate("-", 50))

stats = Repo.one(
  from j in "oban_jobs",
  where: j.worker == "Elixir.Cinegraph.Workers.TMDbDetailsWorker",
  select: %{
    total: count(j.id),
    full_imports: fragment("COUNT(*) FILTER (WHERE ? ->> 'import_type' = 'full')", j.meta),
    soft_imports: fragment("COUNT(*) FILTER (WHERE ? ->> 'import_type' = 'soft')", j.meta),
    failed_lookups: fragment("COUNT(*) FILTER (WHERE ? ->> 'failure_reason' = 'no_tmdb_match')", j.meta),
    with_enrichment: fragment("COUNT(*) FILTER (WHERE (? ->> 'enrichment_queued')::boolean = true)", j.meta),
    with_collaboration: fragment("COUNT(*) FILTER (WHERE (? ->> 'collaboration_queued')::boolean = true)", j.meta)
  }
)

IO.puts("Total TMDb worker jobs: #{stats.total}")
IO.puts("- Full imports: #{stats.full_imports}")
IO.puts("- Soft imports: #{stats.soft_imports}")
IO.puts("- Failed lookups: #{stats.failed_lookups}")
IO.puts("- With OMDb enrichment: #{stats.with_enrichment}")
IO.puts("- With collaboration processing: #{stats.with_collaboration}")

# 4. Recent successful imports
IO.puts("\n4. Recent Successful Imports:")
IO.puts(String.duplicate("-", 50))

recent_imports = Repo.all(
  from j in "oban_jobs",
  where: j.worker == "Elixir.Cinegraph.Workers.TMDbDetailsWorker",
  where: j.state == "completed",
  where: fragment("? ->> 'status' = ?", j.meta, "imported"),
  select: %{
    movie_title: fragment("? ->> 'movie_title'", j.meta),
    import_type: fragment("? ->> 'import_type'", j.meta),
    imdb_id: fragment("? ->> 'imdb_id'", j.meta),
    completed_at: j.completed_at
  },
  order_by: [desc: j.completed_at],
  limit: 5
)

Enum.each(recent_imports, fn import ->
  type_emoji = if import.import_type == "full", do: "✅", else: "⚠️"
  imdb = if import.imdb_id, do: " (IMDb: #{import.imdb_id})", else: ""
  IO.puts("  #{type_emoji} #{import.movie_title}#{imdb} - #{import.import_type} import")
end)