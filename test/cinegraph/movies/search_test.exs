defmodule Cinegraph.Movies.SearchTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.{Genre, Movie, Search}

  setup do
    Cachex.clear(:movies_cache)
    :ok
  end

  describe "search_movies/1 genre filters" do
    test "single genre returns movies with that genre" do
      drama = insert_genre!("Drama")
      comedy = insert_genre!("Comedy")

      drama_only = insert_movie!("Genre Single Drama")
      comedy_only = insert_movie!("Genre Single Comedy")

      add_genres!(drama_only, [drama])
      add_genres!(comedy_only, [comedy])

      assert {:ok, {movies, _meta}} = search_by_genres([drama.id])
      assert movie_titles(movies) == ["Genre Single Drama"]
    end

    test "stacked genres return only movies with all selected genres" do
      drama = insert_genre!("Drama")
      comedy = insert_genre!("Comedy")

      _drama_only =
        insert_movie!("Genre Stack Drama")
        |> add_genres!([drama])

      _comedy_only =
        insert_movie!("Genre Stack Comedy")
        |> add_genres!([comedy])

      _both =
        insert_movie!("Genre Stack Both")
        |> add_genres!([drama, comedy])

      assert {:ok, {movies, meta}} = search_by_genres([drama.id, comedy.id])
      assert movie_titles(movies) == ["Genre Stack Both"]
      assert meta.total_count == 1
    end

    test "duplicate genre params do not make the all-genres match impossible" do
      drama = insert_genre!("Drama")
      comedy = insert_genre!("Comedy")

      _both =
        insert_movie!("Genre Duplicate Both")
        |> add_genres!([drama, comedy])

      assert {:ok, {movies, meta}} = search_by_genres([drama.id, comedy.id, comedy.id])
      assert movie_titles(movies) == ["Genre Duplicate Both"]
      assert meta.total_count == 1
    end

    test "malformed and blank genre params normalize away safely" do
      drama = insert_genre!("Drama")

      _movie =
        insert_movie!("Genre Malformed Drama")
        |> add_genres!([drama])

      assert {:ok, {movies, meta}} =
               Search.search_movies(%{
                 "genres[]" => ["not-a-genre", "", to_string(drama.id)],
                 "per_page" => "10",
                 "sort" => "title_asc"
               })

      assert movie_titles(movies) == ["Genre Malformed Drama"]
      assert meta.total_count == 1
    end
  end

  defp search_by_genres(genre_ids) do
    Search.search_movies(%{
      "genres[]" => Enum.map(genre_ids, &to_string/1),
      "per_page" => "10",
      "sort" => "title_asc"
    })
  end

  defp insert_movie!(title) do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: title,
      original_title: title,
      release_date: ~D[2024-01-01]
    })
    |> Repo.insert!()
  end

  defp insert_genre!(name) do
    Repo.insert!(%Genre{
      tmdb_id: System.unique_integer([:positive]),
      name: "#{name} #{System.unique_integer([:positive])}"
    })
  end

  defp add_genres!(%Movie{} = movie, genres) do
    rows =
      Enum.map(genres, fn genre ->
        %{movie_id: movie.id, genre_id: genre.id}
      end)

    Repo.insert_all("movie_genres", rows)
    movie
  end

  defp movie_titles(movies), do: Enum.map(movies, & &1.title)
end
