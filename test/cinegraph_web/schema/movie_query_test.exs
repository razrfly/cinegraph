defmodule CinegraphWeb.Schema.MovieQueryTest do
  use Cinegraph.DataCase, async: true

  alias CinegraphWeb.Schema
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie

  # Helper to run a GraphQL query against the schema directly
  defp run_query(query, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    variables = Keyword.get(opts, :variables, %{})
    Absinthe.run(query, Schema, context: context, variables: variables)
  end

  # Insert a minimal movie fixture directly
  defp insert_movie(attrs) do
    defaults = %{
      tmdb_id: :rand.uniform(999_999),
      title: "Test Movie",
      import_status: "full"
    }

    {:ok, movie} =
      %Movie{}
      |> Movie.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    movie
  end

  describe "movie query" do
    test "fetches a movie by tmdb_id" do
      movie = insert_movie(%{tmdb_id: 10_001, title: "Fight Club"})

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          title
          tmdbId
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} = run_query(query)
      assert result["title"] == "Fight Club"
      assert result["tmdbId"] == movie.tmdb_id
    end

    test "returns nil for unknown tmdb_id" do
      query = """
      query {
        movie(tmdbId: 999999999) {
          title
        }
      }
      """

      assert {:ok, %{data: %{"movie" => nil}, errors: errors}} = run_query(query)
      assert Enum.any?(errors, fn e -> e.message == "Movie not found" end)
    end

    test "fetches a movie by slug" do
      movie = insert_movie(%{tmdb_id: 10_002, title: "The Godfather"})

      query = """
      query {
        movie(slug: "#{movie.slug}") {
          title
          slug
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} = run_query(query)
      assert result["title"] == "The Godfather"
      assert result["slug"] == movie.slug
    end

    test "ratings returns nil values when no external metrics exist" do
      movie = insert_movie(%{tmdb_id: 10_003})

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          ratings {
            tmdb
            imdb
            rottenTomatoes
            metacritic
          }
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} = run_query(query)
      ratings = result["ratings"]
      assert ratings["tmdb"] == nil
      assert ratings["imdb"] == nil
      assert ratings["rottenTomatoes"] == nil
      assert ratings["metacritic"] == nil
    end
  end

  describe "movies batch query" do
    test "fetches multiple movies by tmdb_ids" do
      m1 = insert_movie(%{tmdb_id: 20_001, title: "Movie A"})
      m2 = insert_movie(%{tmdb_id: 20_002, title: "Movie B"})

      query = """
      query {
        movies(tmdbIds: [#{m1.tmdb_id}, #{m2.tmdb_id}]) {
          title
          tmdbId
        }
      }
      """

      assert {:ok, %{data: %{"movies" => results}}} = run_query(query)
      titles = Enum.map(results, & &1["title"])
      assert "Movie A" in titles
      assert "Movie B" in titles
    end

    test "returns empty list for unknown tmdb_ids" do
      query = """
      query {
        movies(tmdbIds: [999999990, 999999991]) {
          title
        }
      }
      """

      assert {:ok, %{data: %{"movies" => []}}} = run_query(query)
    end
  end

  describe "searchMovies query" do
    test "returns movies matching the query string" do
      insert_movie(%{tmdb_id: 30_001, title: "Inception"})
      insert_movie(%{tmdb_id: 30_002, title: "Interstellar"})

      query = """
      query {
        searchMovies(query: "Incep") {
          title
        }
      }
      """

      assert {:ok, %{data: %{"searchMovies" => results}}} = run_query(query)
      titles = Enum.map(results, & &1["title"])
      assert "Inception" in titles
      refute "Interstellar" in titles
    end

    test "respects the limit argument" do
      for i <- 1..5, do: insert_movie(%{tmdb_id: 40_000 + i, title: "The Movie #{i}"})

      query = """
      query {
        searchMovies(query: "The Movie", limit: 3) {
          title
        }
      }
      """

      assert {:ok, %{data: %{"searchMovies" => results}}} = run_query(query)
      assert length(results) <= 3
    end
  end

  describe "authentication" do
    setup do
      Application.put_env(:cinegraph, :api_key, "secret-key")
      on_exit(fn -> Application.delete_env(:cinegraph, :api_key) end)
      :ok
    end

    test "rejects requests without a valid token" do
      query = """
      query {
        movie(tmdbId: 550) {
          title
        }
      }
      """

      assert {:ok, %{errors: errors}} = run_query(query, context: %{})
      assert Enum.any?(errors, fn e -> e.message == "unauthorized" end)
    end

    test "allows requests with the correct token" do
      movie = insert_movie(%{tmdb_id: 50_001, title: "Authenticated Movie"})

      query = """
      query {
        movie(tmdbId: #{movie.tmdb_id}) {
          title
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} =
               run_query(query, context: %{auth_token: "secret-key"})

      assert result["title"] == "Authenticated Movie"
    end
  end
end
