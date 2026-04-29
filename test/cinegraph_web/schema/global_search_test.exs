defmodule CinegraphWeb.Schema.GlobalSearchTest do
  use Cinegraph.DataCase, async: false

  alias CinegraphWeb.Schema
  alias Cinegraph.Movies.{Movie, Person}

  defp run_query(query, opts \\ []) do
    context = Keyword.get(opts, :context, %{auth_token: nil})
    Absinthe.run(query, Schema, context: context)
  end

  defp insert_movie(attrs) do
    defaults = %{
      tmdb_id: :rand.uniform(999_999),
      title: "Test Movie",
      import_status: "full"
    }

    {:ok, m} =
      %Movie{}
      |> Movie.changeset(Map.merge(defaults, attrs))
      |> Cinegraph.Repo.insert()

    m
  end

  defp insert_person(attrs) do
    defaults = %{
      tmdb_id: :rand.uniform(999_999),
      name: "Test Person",
      popularity: 1.0,
      known_for_department: "Acting"
    }

    {:ok, p} =
      %Person{}
      |> Person.changeset(Map.merge(defaults, attrs))
      |> Cinegraph.Repo.insert()

    p
  end

  setup do
    Cachex.clear(:movies_cache)
    :ok
  end

  describe "globalSearch query" do
    test "returns grouped results for an authenticated query" do
      movie = insert_movie(%{tmdb_id: 60_001, title: "GraphQLandia"})
      _person = insert_person(%{tmdb_id: 60_002, name: "GraphQLandia Hero"})

      query = """
      query {
        globalSearch(q: "graphqlandia") {
          totalCount
          films { tmdbId title slug year director }
          people { tmdbId name knownForDepartment }
          lists { name slug }
          companies { tmdbId name }
        }
      }
      """

      assert {:ok, %{data: %{"globalSearch" => result}}} = run_query(query)
      assert is_integer(result["totalCount"])
      assert Enum.any?(result["films"], &(&1["tmdbId"] == movie.tmdb_id))
      assert Enum.any?(result["people"], &(&1["name"] == "GraphQLandia Hero"))
      assert is_list(result["lists"])
      assert is_list(result["companies"])
    end

    test "sub-threshold queries return empty groups (not an error)" do
      query = """
      query {
        globalSearch(q: "a") {
          totalCount
          films { title }
          people { name }
        }
      }
      """

      assert {:ok, %{data: %{"globalSearch" => result}}} = run_query(query)
      assert result["totalCount"] == 0
      assert result["films"] == []
      assert result["people"] == []
    end

    test "rejects requests without a valid token when api_key is set" do
      Application.put_env(:cinegraph, :api_key, "secret-key")
      on_exit(fn -> Application.delete_env(:cinegraph, :api_key) end)

      query = """
      query {
        globalSearch(q: "anything") {
          totalCount
        }
      }
      """

      assert {:ok, %{errors: errors}} = run_query(query, context: %{})
      assert Enum.any?(errors, fn e -> e.message == "unauthorized" end)
    end
  end
end
