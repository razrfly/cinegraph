import Ecto.Query
alias Cinegraph.Repo

# Check a specific category to see what nominees it has
ceremony_id = System.get_env("CEREMONY_ID", "50") |> String.to_integer()
ceremony = Repo.get(Cinegraph.Festivals.FestivalCeremony, ceremony_id)

if is_nil(ceremony) do
  IO.puts("Ceremony with ID #{ceremony_id} not found")
  System.halt(1)
end

categories = ceremony.data["categories"] || []

# Find "Best Picture" category
best_picture =
  Enum.find(categories, fn cat ->
    name = cat["category"] || cat[:category]
    name == "Best Picture"
  end)

if best_picture do
  IO.puts("\n=== Best Picture Category ===")
  nominees = best_picture["nominees"] || []
  IO.puts("Number of nominees: #{length(nominees)}")

  Enum.each(nominees, fn nominee ->
    film = nominee["film"] || nominee[:film]
    imdb_id = nominee["film_imdb_id"] || nominee[:film_imdb_id]
    winner = nominee["winner"] || nominee[:winner] || false

    status = if winner, do: "🏆", else: "📽️"
    IO.puts("#{status} #{film} - IMDb: #{imdb_id || "NO IMDB ID"}")
  end)
end

# Check how many movies have IMDb IDs
all_nominees =
  Enum.flat_map(categories, fn cat ->
    cat["nominees"] || []
  end)

with_imdb =
  Enum.count(all_nominees, fn nom ->
    imdb_id = nom["film_imdb_id"] || nom[:film_imdb_id]
    imdb_id != nil and imdb_id != ""
  end)

IO.puts("\n=== IMDb ID Coverage ===")
IO.puts("Total nominees: #{length(all_nominees)}")
IO.puts("With IMDb IDs: #{with_imdb}")
IO.puts("Without IMDb IDs: #{length(all_nominees) - with_imdb}")

# Check unique films (some are nominated multiple times)
unique_films =
  all_nominees
  |> Enum.map(fn nom ->
    imdb_id = nom["film_imdb_id"] || nom[:film_imdb_id]
    film = nom["film"] || nom[:film]
    {imdb_id, film}
  end)
  |> Enum.uniq()
  |> Enum.filter(fn {imdb_id, _} -> imdb_id != nil and imdb_id != "" end)

IO.puts("\n=== Unique Films ===")
IO.puts("Unique films with IMDb IDs: #{length(unique_films)}")

# Check what nominations we actually created
nominations_created =
  Repo.all(
    from n in Cinegraph.Festivals.FestivalNomination,
      join: m in Cinegraph.Movies.Movie,
      on: n.movie_id == m.id,
      where: n.ceremony_id == 50,
      select: %{imdb_id: m.imdb_id, title: m.title}
  )
  |> Enum.uniq_by(& &1.imdb_id)

IO.puts("\n=== Nominations Created ===")
IO.puts("Unique movies with nominations: #{length(nominations_created)}")

Enum.each(Enum.take(nominations_created, 5), fn movie ->
  IO.puts("  - #{movie.title} (#{movie.imdb_id})")
end)
