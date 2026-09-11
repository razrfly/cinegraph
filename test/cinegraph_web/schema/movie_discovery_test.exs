defmodule CinegraphWeb.Schema.MovieDiscoveryTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.{Genre, Keyword, Movie}
  alias Cinegraph.Repo
  alias CinegraphWeb.Schema

  defp run_query(query, variables \\ %{}, context \\ %{}) do
    Absinthe.run(query, Schema, variables: variables, context: context)
  end

  defp insert_movie(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Discovery fixture #{System.unique_integer([:positive])}",
      import_status: "full"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_keyword(tmdb_id, name), do: Repo.insert!(%Keyword{tmdb_id: tmdb_id, name: name})
  defp insert_genre(tmdb_id, name), do: Repo.insert!(%Genre{tmdb_id: tmdb_id, name: name})

  defp tag_movie(movie, keywords, genres \\ []) do
    Repo.insert_all(
      "movie_keywords",
      Enum.map(keywords, &%{movie_id: movie.id, keyword_id: &1.id}),
      on_conflict: :nothing
    )

    Repo.insert_all(
      "movie_genres",
      Enum.map(genres, &%{movie_id: movie.id, genre_id: &1.id}),
      on_conflict: :nothing
    )

    movie
  end

  describe "searchMovieKeywords" do
    test "orders exact, prefix, then substring matches and counts only full movies" do
      exact = insert_keyword(710_001, "Qxmatch")
      prefix = insert_keyword(710_002, "qxmatch abroad")
      substring = insert_keyword(710_003, "inside qxmatch story")

      full = insert_movie(%{tmdb_id: 711_001}) |> tag_movie([exact])
      _full_prefix = insert_movie(%{tmdb_id: 711_002}) |> tag_movie([prefix])

      insert_movie(%{tmdb_id: 711_003, import_status: "soft"})
      |> tag_movie([exact, substring])

      query = """
      query Search($query: String!, $limit: Int) {
        searchMovieKeywords(query: $query, limit: $limit) { tmdbId name movieCount }
      }
      """

      assert {:ok, %{data: %{"searchMovieKeywords" => results}}} =
               run_query(query, %{"query" => "  QXMATCH  ", "limit" => 10})

      assert Enum.map(results, & &1["tmdbId"]) == [
               exact.tmdb_id,
               prefix.tmdb_id,
               substring.tmdb_id
             ]

      assert Enum.map(results, & &1["movieCount"]) == [1, 1, 0]
      assert full.import_status == "full"
    end

    test "treats percent and underscore as literal characters" do
      percent = insert_keyword(710_011, "literal%marker")
      underscore = insert_keyword(710_012, "literal_marker")
      _wildcard_decoy = insert_keyword(710_013, "literalXmarker")

      query = """
      query($query: String!) {
        searchMovieKeywords(query: $query) { tmdbId }
      }
      """

      assert {:ok, %{data: %{"searchMovieKeywords" => [%{"tmdbId" => id}]}}} =
               run_query(query, %{"query" => "%"})

      assert id == percent.tmdb_id

      assert {:ok, %{data: %{"searchMovieKeywords" => [%{"tmdbId" => id}]}}} =
               run_query(query, %{"query" => "_"})

      assert id == underscore.tmdb_id
    end

    test "rejects blank, overlong, and out-of-range inputs and returns [] for no match" do
      query = """
      query($query: String!, $limit: Int) {
        searchMovieKeywords(query: $query, limit: $limit) { tmdbId }
      }
      """

      for variables <- [
            %{"query" => "   ", "limit" => 10},
            %{"query" => String.duplicate("x", 101), "limit" => 10},
            %{"query" => "valid", "limit" => 0},
            %{"query" => "valid", "limit" => 51}
          ] do
        assert {:ok, %{errors: [_ | _]}} = run_query(query, variables)
      end

      assert {:ok, %{data: %{"searchMovieKeywords" => []}}} =
               run_query(query, %{"query" => "no-such-keyword-9f90", "limit" => 10})
    end
  end

  describe "movieGenres" do
    test "uses stable ordering and eligible movie counts" do
      zulu = insert_genre(720_001, "Zulu Fixture")
      alpha = insert_genre(720_002, "alpha Fixture")
      insert_movie(%{tmdb_id: 721_001}) |> tag_movie([], [alpha])
      insert_movie(%{tmdb_id: 721_002, import_status: "soft"}) |> tag_movie([], [alpha, zulu])

      query = "query { movieGenres { tmdbId name movieCount } }"

      assert {:ok, %{data: %{"movieGenres" => results}}} = run_query(query)
      fixtures = Enum.filter(results, &String.ends_with?(&1["name"], "Fixture"))

      assert Enum.map(fixtures, & &1["tmdbId"]) == [alpha.tmdb_id, zulu.tmdb_id]
      assert Enum.map(fixtures, & &1["movieCount"]) == [1, 0]
    end
  end

  describe "discoverMovies" do
    test "Movie exposes keywords and genres on the existing lookup contract" do
      keyword = insert_keyword(725_001, "lookup-keyword")
      genre = insert_genre(725_101, "Lookup Genre")
      movie = insert_movie(%{tmdb_id: 725_201}) |> tag_movie([keyword], [genre])

      query = """
      query($tmdbId: Int!) {
        movie(tmdbId: $tmdbId) {
          tmdbId
          keywords { tmdbId name }
          genres { tmdbId name }
        }
      }
      """

      assert {:ok, %{data: %{"movie" => result}}} =
               run_query(query, %{"tmdbId" => movie.tmdb_id})

      assert result["keywords"] == [%{"tmdbId" => keyword.tmdb_id, "name" => keyword.name}]
      assert result["genres"] == [%{"tmdbId" => genre.tmdb_id, "name" => genre.name}]
    end

    test "finds a title-independent keyword match with real metadata and a missing poster" do
      keyword = insert_keyword(730_001, "thematic-fixture")
      other_keyword = insert_keyword(730_002, "other-fixture")
      genre = insert_genre(730_101, "Fixture Drama")

      movie =
        insert_movie(%{
          tmdb_id: 731_001,
          title: "A Completely Unrelated Title",
          release_date: ~D[2024-03-01],
          poster_path: nil
        })
        |> tag_movie([keyword, other_keyword], [genre])

      insert_movie(%{tmdb_id: 731_002, import_status: "soft"}) |> tag_movie([keyword], [genre])

      query = """
      query($keywords: [Int!]) {
        discoverMovies(keywordTmdbIds: $keywords) {
          edges {
            node {
              movie { tmdbId title posterPath keywords { tmdbId name } genres { tmdbId name } }
              matchedKeywords { tmdbId name }
              matchedGenres { tmdbId name }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
      """

      assert {:ok, %{data: %{"discoverMovies" => connection}}} =
               run_query(query, %{"keywords" => [keyword.tmdb_id]})

      assert [%{"node" => node}] = connection["edges"]
      assert node["movie"]["tmdbId"] == movie.tmdb_id
      assert node["movie"]["posterPath"] == nil

      assert Enum.map(node["movie"]["keywords"], & &1["tmdbId"]) |> Enum.sort() ==
               [keyword.tmdb_id, other_keyword.tmdb_id]

      assert node["movie"]["genres"] == [%{"tmdbId" => genre.tmdb_id, "name" => genre.name}]
      assert node["matchedKeywords"] == [%{"tmdbId" => keyword.tmdb_id, "name" => keyword.name}]
      assert node["matchedGenres"] == []
    end

    test "implements ALL and ANY semantics without duplicate movies" do
      one = insert_keyword(740_001, "one-fixture")
      two = insert_keyword(740_002, "two-fixture")
      both = insert_movie(%{tmdb_id: 741_001}) |> tag_movie([one, two])
      only_one = insert_movie(%{tmdb_id: 741_002}) |> tag_movie([one])

      query = """
      query($ids: [Int!], $match: MovieDiscoveryMatch) {
        discoverMovies(keywordTmdbIds: $ids, keywordMatch: $match) {
          edges { node { movie { tmdbId } matchedKeywords { tmdbId } } }
        }
      }
      """

      assert {:ok, %{data: %{"discoverMovies" => %{"edges" => all_edges}}}} =
               run_query(query, %{"ids" => [one.tmdb_id, two.tmdb_id], "match" => "ALL"})

      assert Enum.map(all_edges, &get_in(&1, ["node", "movie", "tmdbId"])) == [both.tmdb_id]

      assert {:ok, %{data: %{"discoverMovies" => %{"edges" => any_edges}}}} =
               run_query(query, %{"ids" => [one.tmdb_id, two.tmdb_id], "match" => "ANY"})

      assert MapSet.new(Enum.map(any_edges, &get_in(&1, ["node", "movie", "tmdbId"]))) ==
               MapSet.new([both.tmdb_id, only_one.tmdb_id])

      assert length(any_edges) == 2
    end

    test "implements ALL and ANY independently for genres" do
      one = insert_genre(745_001, "Genre One")
      two = insert_genre(745_002, "Genre Two")
      both = insert_movie(%{tmdb_id: 746_001}) |> tag_movie([], [one, two])
      only_one = insert_movie(%{tmdb_id: 746_002}) |> tag_movie([], [one])

      query = """
      query($ids: [Int!], $match: MovieDiscoveryMatch) {
        discoverMovies(genreTmdbIds: $ids, genreMatch: $match) {
          edges { node { movie { tmdbId } } }
        }
      }
      """

      assert {:ok, %{data: %{"discoverMovies" => %{"edges" => all_edges}}}} =
               run_query(query, %{"ids" => [one.tmdb_id, two.tmdb_id], "match" => "ALL"})

      assert Enum.map(all_edges, &get_in(&1, ["node", "movie", "tmdbId"])) == [both.tmdb_id]

      assert {:ok, %{data: %{"discoverMovies" => %{"edges" => any_edges}}}} =
               run_query(query, %{"ids" => [one.tmdb_id, two.tmdb_id], "match" => "ANY"})

      assert MapSet.new(Enum.map(any_edges, &get_in(&1, ["node", "movie", "tmdbId"]))) ==
               MapSet.new([both.tmdb_id, only_one.tmdb_id])
    end

    test "combines keyword and genre groups with AND" do
      keyword = insert_keyword(750_001, "and-keyword")
      genre = insert_genre(750_101, "And Genre")
      both = insert_movie(%{tmdb_id: 751_001}) |> tag_movie([keyword], [genre])
      insert_movie(%{tmdb_id: 751_002}) |> tag_movie([keyword], [])
      insert_movie(%{tmdb_id: 751_003}) |> tag_movie([], [genre])

      query = """
      query($keywords: [Int!], $genres: [Int!]) {
        discoverMovies(keywordTmdbIds: $keywords, genreTmdbIds: $genres) {
          edges { node { movie { tmdbId } matchedKeywords { tmdbId } matchedGenres { tmdbId } } }
        }
      }
      """

      assert {:ok, %{data: %{"discoverMovies" => %{"edges" => [edge]}}}} =
               run_query(query, %{"keywords" => [keyword.tmdb_id], "genres" => [genre.tmdb_id]})

      assert get_in(edge, ["node", "movie", "tmdbId"]) == both.tmdb_id
      assert get_in(edge, ["node", "matchedKeywords"]) == [%{"tmdbId" => keyword.tmdb_id}]
      assert get_in(edge, ["node", "matchedGenres"]) == [%{"tmdbId" => genre.tmdb_id}]
    end

    test "deduplicates requested IDs and rejects unknown IDs" do
      keyword = insert_keyword(760_001, "duplicate-fixture")
      movie = insert_movie(%{tmdb_id: 761_001}) |> tag_movie([keyword])

      query = """
      query($ids: [Int!]) {
        discoverMovies(keywordTmdbIds: $ids) { edges { node { movie { tmdbId } } } }
      }
      """

      assert {:ok, %{data: %{"discoverMovies" => %{"edges" => [edge]}}}} =
               run_query(query, %{"ids" => [keyword.tmdb_id, keyword.tmdb_id]})

      assert get_in(edge, ["node", "movie", "tmdbId"]) == movie.tmdb_id

      assert {:ok, %{data: %{"discoverMovies" => nil}, errors: errors}} =
               run_query(query, %{"ids" => [keyword.tmdb_id, 999_999_991]})

      assert Enum.any?(
               errors,
               &String.contains?(&1.message, "Unknown keyword TMDb IDs: 999999991")
             )

      genre_query = """
      query { discoverMovies(genreTmdbIds: [999999992]) { edges { cursor } } }
      """

      assert {:ok, %{errors: genre_errors}} = run_query(genre_query)
      assert Enum.any?(genre_errors, &String.contains?(&1.message, "Unknown genre TMDb IDs"))
    end

    test "rejects empty, invalid, oversized, and out-of-range inputs" do
      query = """
      query($keywords: [Int!], $first: Int) {
        discoverMovies(keywordTmdbIds: $keywords, first: $first) { edges { cursor } }
      }
      """

      for variables <- [
            %{"keywords" => [], "first" => 12},
            %{"keywords" => [0], "first" => 12},
            %{"keywords" => Enum.to_list(1..11), "first" => 12},
            %{"keywords" => [1], "first" => 0},
            %{"keywords" => [1], "first" => 51}
          ] do
        assert {:ok, %{errors: [_ | _]}} = run_query(query, variables)
      end
    end

    test "returns an empty connection for a known filter with no matches" do
      keyword = insert_keyword(770_001, "empty-fixture")

      query = """
      query($ids: [Int!]) {
        discoverMovies(keywordTmdbIds: $ids) {
          edges { cursor }
          pageInfo { endCursor hasNextPage }
        }
      }
      """

      assert {:ok,
              %{
                data: %{
                  "discoverMovies" => %{
                    "edges" => [],
                    "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
                  }
                }
              }} = run_query(query, %{"ids" => [keyword.tmdb_id]})
    end

    test "paginates deterministically across tied and null release dates" do
      keyword = insert_keyword(780_001, "cursor-fixture")

      for {tmdb_id, date} <- [
            {781_004, ~D[2025-01-01]},
            {781_003, ~D[2025-01-01]},
            {781_002, nil},
            {781_001, nil}
          ] do
        insert_movie(%{tmdb_id: tmdb_id, release_date: date}) |> tag_movie([keyword])
      end

      query = """
      query($ids: [Int!], $after: String) {
        discoverMovies(keywordTmdbIds: $ids, first: 1, after: $after) {
          edges { cursor node { movie { tmdbId releaseDate } } }
          pageInfo { endCursor hasNextPage }
        }
      }
      """

      Enum.reduce([781_004, 781_003, 781_002, 781_001], nil, fn expected_id, cursor ->
        assert {:ok, %{data: %{"discoverMovies" => page}}} =
                 run_query(query, %{
                   "ids" => [keyword.tmdb_id, keyword.tmdb_id],
                   "after" => cursor
                 })

        assert [%{"node" => %{"movie" => %{"tmdbId" => ^expected_id}}}] = page["edges"]
        assert page["pageInfo"]["hasNextPage"] == (expected_id != 781_001)
        page["pageInfo"]["endCursor"]
      end)
    end

    test "rejects malformed and filter-incompatible cursors" do
      one = insert_keyword(790_001, "cursor-one")
      two = insert_keyword(790_002, "cursor-two")
      insert_movie(%{tmdb_id: 791_001}) |> tag_movie([one, two])

      query = """
      query($ids: [Int!], $after: String) {
        discoverMovies(keywordTmdbIds: $ids, first: 1, after: $after) {
          edges { cursor }
          pageInfo { endCursor }
        }
      }
      """

      assert {:ok, %{data: %{"discoverMovies" => first}}} =
               run_query(query, %{"ids" => [one.tmdb_id]})

      cursor = first["pageInfo"]["endCursor"]

      assert {:ok, %{errors: malformed_errors}} =
               run_query(query, %{"ids" => [one.tmdb_id], "after" => "not-a-cursor"})

      assert Enum.any?(malformed_errors, &(&1.message == "Invalid cursor"))

      assert {:ok, %{errors: mismatch_errors}} =
               run_query(query, %{"ids" => [two.tmdb_id], "after" => cursor})

      assert Enum.any?(mismatch_errors, &String.contains?(&1.message, "does not match"))
    end

    test "uses a fixed query count for batched movie metadata" do
      keyword = insert_keyword(795_001, "query-count-keyword")
      genre = insert_genre(795_101, "Query Count Genre")

      for tmdb_id <- 795_201..795_205 do
        insert_movie(%{tmdb_id: tmdb_id}) |> tag_movie([keyword], [genre])
      end

      query = """
      query($keywords: [Int!], $genres: [Int!]) {
        discoverMovies(keywordTmdbIds: $keywords, genreTmdbIds: $genres) {
          edges { node { movie { tmdbId keywords { tmdbId } genres { tmdbId } } } }
        }
      }
      """

      handler_id = "movie-discovery-query-count-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:cinegraph, :repo, :query],
          fn _, _, _, _ -> send(test_pid, :repo_query) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{data: %{"discoverMovies" => %{"edges" => edges}}}} =
               run_query(query, %{
                 "keywords" => [keyword.tmdb_id],
                 "genres" => [genre.tmdb_id]
               })

      assert length(edges) == 5
      assert collect_query_count() == 5
    end

    test "protects all discovery fields with the existing API auth middleware" do
      Application.put_env(:cinegraph, :api_key, "discovery-secret")
      on_exit(fn -> Application.delete_env(:cinegraph, :api_key) end)

      for query <- [
            "query { searchMovieKeywords(query: \"war\") { tmdbId } }",
            "query { movieGenres { tmdbId } }",
            "query { discoverMovies(keywordTmdbIds: [1]) { edges { cursor } } }"
          ] do
        assert {:ok, %{errors: errors}} = run_query(query)
        assert Enum.any?(errors, &(&1.message == "unauthorized"))
      end

      assert {:ok, %{data: %{"movieGenres" => genres}}} =
               run_query("query { movieGenres { tmdbId } }", %{}, %{
                 auth_token: "discovery-secret"
               })

      assert is_list(genres)
    end
  end

  defp collect_query_count(count \\ 0) do
    receive do
      :repo_query -> collect_query_count(count + 1)
    after
      20 -> count
    end
  end
end
