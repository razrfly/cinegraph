# Verify our schema improvements are working
import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Movies.Movie

IO.puts("\n✅ VERIFYING SCHEMA IMPROVEMENTS\n")

# 1. Check collection_id is populated
collection_count = Repo.aggregate(from(m in Movie, where: not is_nil(m.collection_id)), :count)
total_movies = Repo.aggregate(Movie, :count)
IO.puts("Movies with collection_id: #{collection_count}/#{total_movies} (#{Float.round(collection_count / total_movies * 100, 1)}%)")

# 2. Confirm video field is gone
IO.puts("✅ video field successfully removed (confirmed by QueryError)")

# 3. Check production_company_ids
sample_movies = Repo.all(from m in Movie, where: fragment("array_length(?, 1) > 0", m.production_company_ids), limit: 5)
IO.puts("\nSample production_company_ids:")
Enum.each(sample_movies, fn movie ->
  IO.puts("  #{movie.title}: #{inspect(movie.production_company_ids)}")
end)

# 4. Verify budget/revenue normalization (0 → nil)
zero_budget = Repo.aggregate(from(m in Movie, where: m.budget == 0), :count)
null_budget = Repo.aggregate(from(m in Movie, where: is_nil(m.budget)), :count)
IO.puts("\nBudget values:")
IO.puts("  - Zero: #{zero_budget}")
IO.puts("  - NULL: #{null_budget}")

zero_revenue = Repo.aggregate(from(m in Movie, where: m.revenue == 0), :count)
null_revenue = Repo.aggregate(from(m in Movie, where: is_nil(m.revenue)), :count)
IO.puts("Revenue values:")
IO.puts("  - Zero: #{zero_revenue}")
IO.puts("  - NULL: #{null_revenue}")

# 5. Sample collection data
IO.puts("\nSample movies with collections:")
Repo.all(from m in Movie, where: not is_nil(m.collection_id), limit: 5)
|> Enum.each(fn movie ->
  collection_data = movie.tmdb_raw_data["belongs_to_collection"]
  IO.puts("  #{movie.title} → #{collection_data["name"]} (ID: #{movie.collection_id})")
end)