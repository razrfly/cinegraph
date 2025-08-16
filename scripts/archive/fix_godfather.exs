# Fix The Godfather with proper TMDB data
Mix.Task.run("app.start")

IO.puts("🔧 Fixing The Godfather movie data...")

# Get The Godfather movie
godfather = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, tmdb_id: 238)

if godfather do
  IO.puts("Found The Godfather: #{godfather.title}")
  IO.puts("Current poster_path: #{godfather.poster_path}")
  
  # Update with proper poster path and other missing data
  changeset = Ecto.Changeset.change(godfather, %{
    poster_path: "/3bhkrj58Vtu7enYsRolD1fZdja1.jpg",
    backdrop_path: "/tmU7GeKVybMWFButWEGl2M4GeiP.jpg",
    tagline: "An offer you can't refuse.",
    budget: 6000000,
    revenue: 245066411,
    homepage: "https://www.paramountmovies.com/movies/the-godfather"
  })
  
  case Cinegraph.Repo.update(changeset) do
    {:ok, updated_movie} ->
      IO.puts("✅ Successfully updated The Godfather")
      IO.puts("New poster_path: #{updated_movie.poster_path}")
    {:error, changeset} ->
      IO.puts("❌ Failed to update: #{inspect(changeset.errors)}")
  end
else
  IO.puts("❌ The Godfather not found")
end

IO.puts("🎬 Done!")