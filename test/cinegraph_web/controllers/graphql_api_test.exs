defmodule CinegraphWeb.GraphqlApiTest do
  use CinegraphWeb.ConnCase, async: false

  import Cinegraph.ClerkTestHelpers

  alias Cinegraph.ApiCredentials

  setup do
    previous_key = Application.get_env(:cinegraph, :legacy_api_key)
    previous_expiry = Application.get_env(:cinegraph, :legacy_api_key_expires_at)
    previous_bypass = Application.get_env(:cinegraph, :api_auth_local_bypass)

    Application.put_env(:cinegraph, :api_auth_local_bypass, false)

    on_exit(fn ->
      if is_nil(previous_key),
        do: Application.delete_env(:cinegraph, :legacy_api_key),
        else: Application.put_env(:cinegraph, :legacy_api_key, previous_key)

      if is_nil(previous_expiry),
        do: Application.delete_env(:cinegraph, :legacy_api_key_expires_at),
        else: Application.put_env(:cinegraph, :legacy_api_key_expires_at, previous_expiry)

      Application.put_env(:cinegraph, :api_auth_local_bypass, previous_bypass)
      reset_cache()
    end)

    :ok
  end

  test "accepts the configured Bearer token and rejects missing or incorrect tokens", %{
    conn: conn
  } do
    Application.put_env(:cinegraph, :legacy_api_key, "http-secret")

    Application.put_env(
      :cinegraph,
      :legacy_api_key_expires_at,
      DateTime.add(DateTime.utc_now(), 3600)
    )

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
    Application.put_env(:cinegraph, :legacy_api_key, "")

    response =
      conn
      |> post("/api/graphql", %{query: "query { movieGenres { tmdbId } }"})
      |> json_response(200)

    assert get_in(response, ["errors", Access.at(0), "message"]) == "unauthorized"
  end

  test "local bypass only permits missing credentials, never malformed credentials", %{conn: conn} do
    Application.put_env(:cinegraph, :api_auth_local_bypass, true)
    body = %{query: "query { movieGenres { tmdbId } }"}

    assert conn
           |> post("/api/graphql", body)
           |> json_response(200)
           |> get_in(["data", "movieGenres"])

    response =
      conn
      |> put_req_header("authorization", "Bearer malformed")
      |> post("/api/graphql", body)
      |> json_response(200)

    assert get_in(response, ["errors", Access.at(0), "message"]) == "unauthorized"
  end

  test "a revoked registry-format credential never falls back to the matching legacy value", %{
    conn: conn
  } do
    {:ok, client} =
      ApiCredentials.create_client(%{
        slug: "registry-dispatch-test",
        label: "Registry dispatch test",
        owner_contact: "ops@example.com",
        environment: "test",
        scopes: ["catalog:read"]
      })

    {:ok, key, token} =
      ApiCredentials.issue_key(client, %{
        label: "revoked",
        created_by: "test@example.com",
        expires_at: nil
      })

    {:ok, _} = ApiCredentials.revoke_key(key.public_id)
    Application.put_env(:cinegraph, :legacy_api_key, token)

    Application.put_env(
      :cinegraph,
      :legacy_api_key_expires_at,
      DateTime.add(DateTime.utc_now(), 3600)
    )

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/graphql", %{query: "query { movieGenres { tmdbId } }"})
      |> json_response(200)

    assert get_in(response, ["errors", Access.at(0), "message"]) == "unauthorized"
  end

  test "caps GraphQL transport batches while preserving small batches", %{conn: conn} do
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
    Application.put_env(:cinegraph, :api_auth_local_bypass, true)
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

  test "authenticates a registry key once for aliases and batches, with non-secret telemetry", %{
    conn: conn
  } do
    {:ok, client} =
      ApiCredentials.create_client(%{
        slug: "wordhoard-preview",
        label: "Wordhoard preview",
        owner_contact: "dictionary@example.com",
        environment: "preview",
        scopes: ["catalog:read"]
      })

    {:ok, key, token} =
      ApiCredentials.issue_key(client, %{
        label: "test",
        created_by: "test@example.com",
        expires_at: nil
      })

    user_count = Cinegraph.Repo.aggregate(Cinegraph.Accounts.User, :count)

    handler_id = "graphql-api-auth-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:cinegraph, :api_auth, :stop],
        [:cinegraph, :api_auth, :catalog_field],
        [:cinegraph, :repo, :query]
      ],
      fn event, measurements, metadata, _ ->
        if event != [:cinegraph, :repo, :query] or metadata[:source] == "api_keys" do
          send(test_pid, {:auth_telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    operation = %{
      query:
        "query Parts { first: movieGenres { tmdbId } second: movieGenres { ...Ids } } fragment Ids on MovieMetadataVocabularyTerm { tmdbId }"
    }

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post_json([operation, operation])
      |> json_response(200)

    assert length(response) == 2
    assert Enum.all?(response, &is_list(get_in(&1, ["payload", "data", "first"])))
    assert Cinegraph.Repo.aggregate(Cinegraph.Accounts.User, :count) == user_count

    assert_receive {:auth_telemetry, [:cinegraph, :api_auth, :stop], %{count: 1}, auth_meta}
    assert auth_meta.client_id == client.id
    assert auth_meta.key_id == key.id
    refute inspect(auth_meta) =~ token

    assert_receive {:auth_telemetry, [:cinegraph, :api_auth, :catalog_field], %{request_cost: 1},
                    field_meta}

    assert field_meta.client_id == client.id
    assert field_meta.key_id == key.id
    refute inspect(field_meta) =~ token

    assert_receive {:auth_telemetry, [:cinegraph, :repo, :query], _, %{source: "api_keys"}}
    refute_receive {:auth_telemetry, [:cinegraph, :repo, :query], _, %{source: "api_keys"}}, 20
  end

  test "a valid Clerk user remains distinct and does not gain catalog access", %{conn: conn} do
    jwk = install_jwks()
    user = user_fixture(%{email: "clerk-catalog-policy@example.com"})

    token =
      sign_token(jwk, %{
        "sub" => "user_catalog_policy",
        "userId" => Integer.to_string(user.id),
        "email" => user.email
      })

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/graphql", %{query: "query { movieGenres { tmdbId } }"})
      |> json_response(200)

    assert get_in(response, ["errors", Access.at(0), "message"]) == "unauthorized"
  end

  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", Jason.encode!(body))
  end
end
