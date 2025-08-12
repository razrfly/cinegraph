alias Cinegraph.{Repo, Movies.Movie, Movies.ExternalMetric}
import Ecto.Query

IO.puts "\n=== DATA AUDIT REPORT ===\n"

# Check total movies
total_movies = Repo.one(from m in Movie, select: count(m.id))
IO.puts "Total Movies in Database: #{total_movies}"

# Check 1001 movies
movies_1001 = Repo.one(
  from m in Movie,
  where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
  select: count(m.id)
)
IO.puts "1001 Movies Imported: #{movies_1001}"

# Check metrics by source
IO.puts "\n--- External Metrics by Source ---"
metrics = Repo.all(
  from e in ExternalMetric,
  group_by: [e.source, e.metric_type],
  select: {e.source, e.metric_type, count(e.id)},
  order_by: [e.source, e.metric_type]
)

metrics
|> Enum.group_by(fn {source, _, _} -> source end)
|> Enum.each(fn {source, source_metrics} ->
  IO.puts "\n#{source}:"
  Enum.each(source_metrics, fn {_, metric_type, count} ->
    IO.puts "  #{metric_type}: #{count}"
  end)
end)

# Check festival data
IO.puts "\n--- Festival Data ---"
{:ok, result} = Repo.query("SELECT COUNT(*) FROM festival_organizations")
[[org_count]] = result.rows
IO.puts "Festival Organizations: #{org_count}"

{:ok, result} = Repo.query("SELECT COUNT(*) FROM festival_ceremonies")
[[ceremony_count]] = result.rows
IO.puts "Festival Ceremonies: #{ceremony_count}"

{:ok, result} = Repo.query("SELECT COUNT(*) FROM festival_nominations")
[[nom_count]] = result.rows
IO.puts "Festival Nominations: #{nom_count}"

# Check canonical sources distribution
IO.puts "\n--- Canonical Sources Coverage ---"
{:ok, result} = Repo.query("""
  SELECT 
    jsonb_object_keys(canonical_sources) as source,
    COUNT(*) as count
  FROM movies
  WHERE canonical_sources IS NOT NULL
  GROUP BY jsonb_object_keys(canonical_sources)
  ORDER BY count DESC
""")

for [source, count] <- result.rows do
  IO.puts "#{source}: #{count}"
end

IO.puts "\n=== END AUDIT REPORT ===\n"
