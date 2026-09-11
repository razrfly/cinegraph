defmodule CinegraphWeb.GraphqlApiTest do
  use CinegraphWeb.ConnCase, async: false

  setup do
    previous_key = Application.get_env(:cinegraph, :api_key)

    on_exit(fn ->
      if is_nil(previous_key),
        do: Application.delete_env(:cinegraph, :api_key),
        else: Application.put_env(:cinegraph, :api_key, previous_key)
    end)

    :ok
  end

  test "accepts the configured Bearer token and rejects missing or incorrect tokens", %{
    conn: conn
  } do
    Application.put_env(:cinegraph, :api_key, "http-secret")
    body = %{query: "query { movieGenres { tmdbId } }"}

    missing = conn |> post("/api/graphql", body) |> json_response(200)
    assert get_in(missing, ["errors", Access.at(0), "message"]) == "unauthorized"

    assert conn
           |> put_req_header("authorization", "Bearer incorrect")
           |> post("/api/graphql", body)
           |> json_response(200)
           |> get_in(["errors", Access.at(0), "message"]) == "unauthorized"

    response =
      conn
      |> put_req_header("authorization", "Bearer http-secret")
      |> post("/api/graphql", body)
      |> json_response(200)

    assert is_list(get_in(response, ["data", "movieGenres"]))
  end

  test "fails closed when a blank key is configured", %{conn: conn} do
    Application.put_env(:cinegraph, :api_key, "")

    response =
      conn
      |> post("/api/graphql", %{query: "query { movieGenres { tmdbId } }"})
      |> json_response(200)

    assert get_in(response, ["errors", Access.at(0), "message"]) == "unauthorized"
  end

  test "caps GraphQL transport batches while preserving small batches", %{conn: conn} do
    Application.delete_env(:cinegraph, :api_key)
    operation = %{query: "query { __typename }"}

    allowed = conn |> post_json(List.duplicate(operation, 2)) |> json_response(200)
    assert length(allowed) == 2

    rejected = conn |> post_json(List.duplicate(operation, 11)) |> json_response(400)

    assert get_in(rejected, ["errors", Access.at(0), "message"]) ==
             "GraphQL batches are limited to 10 operations"

    multipart_style =
      conn
      |> post("/api/graphql", %{"operations" => Jason.encode!(List.duplicate(operation, 11))})
      |> json_response(400)

    assert get_in(multipart_style, ["errors", Access.at(0), "message"]) ==
             "GraphQL batches are limited to 10 operations"
  end

  test "rejects an aliased discovery document above the complexity budget", %{conn: conn} do
    Application.delete_env(:cinegraph, :api_key)

    field = """
    discoverMovies(keywordTmdbIds: [1], first: 50) {
      edges { cursor node { movie { tmdbId title releaseDate overview posterPath backdropPath } } }
      pageInfo { endCursor hasNextPage }
    }
    """

    selections =
      1..10
      |> Enum.map_join("\n", fn index -> "d#{index}: #{field}" end)

    response =
      conn
      |> post("/api/graphql", %{query: "query { #{selections} }"})
      |> json_response(200)

    assert Enum.any?(response["errors"], &String.contains?(&1["message"], "too complex"))
  end

  test "bounds every supported batch encoding in body and query parameters", %{conn: conn} do
    Application.delete_env(:cinegraph, :api_key)

    for size <- [2, 10, 11], key <- ["_json", "operations"], method <- [:get, :post] do
      batch = Jason.encode!(List.duplicate(%{query: "{ __typename }"}, size))
      params = %{key => batch}

      response =
        case method do
          :get -> get(conn, "/api/graphql?" <> URI.encode_query(params))
          :post -> post(conn, "/api/graphql", params)
        end

      if size <= 10 do
        assert length(json_response(response, 200)) == size
      else
        assert get_in(json_response(response, 400), ["errors", Access.at(0), "message"]) ==
                 "GraphQL batches are limited to 10 operations"
      end
    end
  end

  test "a small batch in one parameter cannot hide an oversized batch in another", %{conn: conn} do
    Application.delete_env(:cinegraph, :api_key)
    small = Jason.encode!([%{query: "{ __typename }"}])
    large = Jason.encode!(List.duplicate(%{query: "{ __typename }"}, 11))

    for params <- [
          %{"_json" => small, "operations" => large},
          %{"_json" => large, "operations" => small}
        ] do
      assert conn |> post("/api/graphql", params) |> json_response(400)
    end
  end

  test "movie links use the configured canonical host", %{conn: conn} do
    Application.delete_env(:cinegraph, :api_key)
    previous = Application.get_env(:cinegraph, :cinegraph_base_url)
    Application.put_env(:cinegraph, :cinegraph_base_url, "https://cinegraph.org/")
    on_exit(fn -> Application.put_env(:cinegraph, :cinegraph_base_url, previous) end)

    movie =
      %Cinegraph.Movies.Movie{}
      |> Cinegraph.Movies.Movie.changeset(%{tmdb_id: 887_661, title: "Canonical Link Fixture"})
      |> Cinegraph.Repo.insert!()

    result =
      conn
      |> post("/api/graphql", %{
        query: "query($id: Int!) { movie(tmdbId: $id) { cinegraphUrl } }",
        variables: %{id: movie.tmdb_id}
      })
      |> json_response(200)

    assert get_in(result, ["data", "movie", "cinegraphUrl"]) ==
             "https://cinegraph.org/movies/#{movie.slug}"
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", Jason.encode!(body))
  end
end
