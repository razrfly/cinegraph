alias Cinegraph.{Repo, Movies.Movie}

movie = Repo.get!(Movie, 9)

IO.puts("=== OMDB METADATA ===")
IO.inspect(movie.external_ids["omdb_metadata"], pretty: true)

IO.puts("\n=== AWARDS DATA ===")
IO.inspect(movie.external_ids["omdb_awards"], pretty: true)