# Test single movie to debug
alias Cinegraph.Repo
alias Cinegraph.Movies

# Start with clean slate
IO.puts("Current movie count: #{Repo.aggregate(Movies.Movie, :count)}")

# Try to create a movie directly
IO.puts("\nCreating movie directly...")
case Movies.create_movie(%{
  tmdb_id: 999,
  title: "Test Movie",
  release_date: ~D[2020-01-01],
  overview: "Test movie"
}) do
  {:ok, movie} ->
    IO.puts("✅ Created movie with ID: #{movie.id}")
  {:error, changeset} ->
    IO.puts("❌ Failed to create movie: #{inspect(changeset.errors)}")
end

IO.puts("Movie count after create: #{Repo.aggregate(Movies.Movie, :count)}")

# Now try comprehensive fetch
IO.puts("\nFetching The Godfather comprehensively...")
case Movies.fetch_and_store_movie_comprehensive(238) do
  {:ok, movie} ->
    IO.puts("✅ Fetched: #{movie.title}")
    IO.puts("Movie ID in database: #{movie.id}")
  {:error, reason} ->
    IO.puts("❌ Failed: #{inspect(reason)}")
end

IO.puts("\nFinal movie count: #{Repo.aggregate(Movies.Movie, :count)}")

# Query the movies directly
movies = Repo.all(Movies.Movie)
IO.puts("Movies in database:")
Enum.each(movies, fn m ->
  IO.puts("  - #{m.id}: #{m.title}")
end)