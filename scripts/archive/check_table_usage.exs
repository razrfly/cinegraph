# Check table usage statistics
alias Cinegraph.Repo
import Ecto.Query

# Get all tables
{:ok, %{rows: tables}} = Repo.query("""
  SELECT table_name 
  FROM information_schema.tables 
  WHERE table_schema = 'public' 
  AND table_type = 'BASE TABLE'
  AND table_name NOT LIKE 'schema_%'
  ORDER BY table_name
""")

IO.puts("\n📊 DATABASE USAGE ANALYSIS\n")
IO.puts("=" |> String.duplicate(80))

# Process each table
{table_stats, total_tables, populated_tables, empty_tables} = 
  Enum.reduce(tables, {[], 0, 0, 0}, fn [table_name], {stats, total, populated, empty} ->
    # Skip schema_migrations
    if table_name != "schema_migrations" do
      # Get row count
      {:ok, %{rows: [[count]]}} = Repo.query("SELECT COUNT(*) FROM #{table_name}")
      
      # Get column count
      {:ok, %{rows: [[col_count]]}} = Repo.query("""
        SELECT COUNT(*) 
        FROM information_schema.columns 
        WHERE table_name = $1
      """, [table_name])
      
      status = if count > 0 do
        {[{table_name, count, col_count, "✅"} | stats], total + 1, populated + 1, empty}
      else
        {[{table_name, count, col_count, "❌"} | stats], total + 1, populated, empty + 1}
      end
    else
      {stats, total, populated, empty}
    end
  end)

# Print table statistics
IO.puts("\nTABLE STATUS:")
IO.puts("-" |> String.duplicate(80))
IO.puts("Table Name                          | Rows      | Columns | Status")
IO.puts("-" |> String.duplicate(80))

table_stats
|> Enum.reverse()
|> Enum.each(fn {name, count, cols, status} ->
  IO.puts("#{String.pad_trailing(name, 35)} | #{String.pad_leading(to_string(count), 9)} | #{String.pad_leading(to_string(cols), 7)} | #{status}")
end)

IO.puts("-" |> String.duplicate(80))
IO.puts("\nSUMMARY:")
IO.puts("Total Tables: #{total_tables}")
IO.puts("Populated Tables: #{populated_tables} (#{Float.round(populated_tables / total_tables * 100, 1)}%)")
IO.puts("Empty Tables: #{empty_tables} (#{Float.round(empty_tables / total_tables * 100, 1)}%)")

# Check specific field usage in movies table
IO.puts("\n\nMOVIES TABLE FIELD USAGE:")
IO.puts("-" |> String.duplicate(80))

movie_fields = [
  {"imdb_id", "imdb_id IS NOT NULL"},
  {"budget", "budget IS NOT NULL AND budget > 0"},
  {"revenue", "revenue IS NOT NULL AND revenue > 0"},
  {"homepage", "homepage IS NOT NULL"},
  {"collection_id", "collection_id IS NOT NULL"},
  {"tagline", "tagline IS NOT NULL"},
  {"external_ids", "external_ids IS NOT NULL AND external_ids != '{}'::jsonb"},
  {"images", "images IS NOT NULL AND images != '{}'::jsonb"}
]

{:ok, %{rows: [[total_movies]]}} = Repo.query("SELECT COUNT(*) FROM movies")

for {field, condition} <- movie_fields do
  {:ok, %{rows: [[count]]}} = Repo.query("SELECT COUNT(*) FROM movies WHERE #{condition}")
  percentage = Float.round(count / total_movies * 100, 1)
  status = if percentage > 50, do: "✅", else: "⚠️"
  
  IO.puts("#{String.pad_trailing(field, 20)} | #{String.pad_leading(to_string(count), 5)}/#{total_movies} (#{String.pad_leading(to_string(percentage), 5)}%) | #{status}")
end

# Check TMDB API data completeness
IO.puts("\n\nTMDB DATA COMPLETENESS:")
IO.puts("-" |> String.duplicate(80))

# Check what we're actually storing from the comprehensive fetch
associations = [
  {"Keywords", "SELECT COUNT(DISTINCT movie_id) FROM movie_keywords"},
  {"Videos", "SELECT COUNT(DISTINCT movie_id) FROM movie_videos"},
  {"Credits", "SELECT COUNT(DISTINCT movie_id) FROM movie_credits"},
  {"Release Dates", "SELECT COUNT(DISTINCT movie_id) FROM movie_release_dates"},
  {"Production Cos", "SELECT COUNT(DISTINCT movie_id) FROM movie_production_companies"},
  {"External Ratings", "SELECT COUNT(DISTINCT movie_id) FROM external_ratings"}
]

for {name, query} <- associations do
  {:ok, %{rows: [[count]]}} = Repo.query(query)
  percentage = Float.round(count / total_movies * 100, 1)
  status = if percentage > 80, do: "✅", else: "⚠️"
  
  IO.puts("#{String.pad_trailing(name, 20)} | #{String.pad_leading(to_string(count), 5)}/#{total_movies} (#{String.pad_leading(to_string(percentage), 5)}%) | #{status}")
end

IO.puts("\n" <> "=" |> String.duplicate(80))