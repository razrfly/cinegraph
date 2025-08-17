# Script to analyze current data and prepare schema fixes
# Run with: mix run analyze_and_fix_schema.exs

import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Movies.{Movie, Person, Credit}

IO.puts("\n🔍 Analyzing current data for schema improvements...\n")

# 1. Check video field usage
video_true_count = Repo.aggregate(from(m in Movie, where: m.video == true), :count)
IO.puts("Movies with video=true: #{video_true_count}")
IO.puts("→ Recommendation: Remove 'video' field (deprecated TMDB field)\n")

# 2. Check for collection data in raw JSON
movies_with_collections = Repo.all(
  from m in Movie,
  where: fragment("?->>'belongs_to_collection' IS NOT NULL", m.tmdb_raw_data),
  select: %{
    id: m.id,
    title: m.title,
    collection: fragment("?->'belongs_to_collection'", m.tmdb_raw_data)
  },
  limit: 5
)

IO.puts("Sample movies with collections:")
Enum.each(movies_with_collections, fn movie ->
  collection = movie.collection
  IO.puts("  - #{movie.title}: #{collection["name"]} (ID: #{collection["id"]})")
end)
IO.puts("→ Recommendation: Add 'collection_id' field to movies table\n")

# 3. Check budget/revenue zeros
zero_budget_count = Repo.aggregate(from(m in Movie, where: m.budget == 0), :count)
zero_revenue_count = Repo.aggregate(from(m in Movie, where: m.revenue == 0), :count)
IO.puts("Movies with budget = 0: #{zero_budget_count}")
IO.puts("Movies with revenue = 0: #{zero_revenue_count}")
IO.puts("→ Recommendation: Consider treating 0 as NULL for budget/revenue\n")

# 4. Check for production companies in raw data
sample_movie = Repo.one(from m in Movie, limit: 1)
if sample_movie && sample_movie.tmdb_raw_data["production_companies"] do
  companies = sample_movie.tmdb_raw_data["production_companies"]
  IO.puts("Sample production companies structure:")
  IO.inspect(Enum.take(companies, 2), limit: :infinity)
  IO.puts("→ Recommendation: Store production_company_ids array instead of names\n")
end

# 5. Suggest schema improvements
IO.puts("\n📝 SCHEMA IMPROVEMENTS NEEDED:")
IO.puts("=" <> String.duplicate("=", 50))
IO.puts("""
1. Remove fields:
   - video (deprecated, always false)

2. Add fields:
   - collection_id :integer (for franchise tracking)
   - production_company_ids {:array, :integer} (replace production_countries string array)

3. Modify behavior:
   - Treat budget/revenue of 0 as NULL during import
   - Store production company IDs instead of country codes

4. Future considerations:
   - Add 'collections' table if we want to track franchise data
   - Add 'production_companies' table for company details
""")

# Generate rollback commands
IO.puts("\n🔧 To implement these changes:")
IO.puts("1. Roll back existing migrations:")
IO.puts("   mix ecto.rollback --all")
IO.puts("\n2. Update migration files with changes")
IO.puts("\n3. Re-run migrations:")
IO.puts("   mix ecto.migrate")
IO.puts("\n4. Re-run the test to verify improvements")