defmodule Cinegraph.SearchTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.{Movie, MovieList, Person, ProductionCompany}
  alias Cinegraph.Search

  setup do
    # Search results live in :movies_cache (a global Cachex). Tests share that
    # cache across runs so we have to clear before each test to avoid hits
    # leaking from previous fixtures.
    Cachex.clear(:movies_cache)
    :ok
  end

  describe "global/2" do
    test "below the minimum query length returns an empty result without hitting the DB" do
      handler_id = attach_telemetry_handler(self(), [[:cinegraph, :search, :group]])

      assert %{films: [], people: [], lists: [], companies: [], total_count: 0} =
               Search.global("a")

      refute_received {:telemetry, [:cinegraph, :search, :group], _, _}

      :telemetry.detach(handler_id)
    end

    test "exact title match outranks newer prefix-only matches" do
      _wrong = insert_movie!("The Godfather Returns", ~D[2030-01-01])
      exact = insert_movie!("The Godfather", ~D[1972-03-24])
      _other = insert_movie!("The Godfather Part II", ~D[1974-12-20])

      result = Search.global("the godfather")

      assert [first | _] = result.films
      assert first.id == exact.id
      assert first.title == "The Godfather"
    end

    test "trigram fallback fires for misspellings" do
      insert_person!("Wong Kar-wai", 700_001, popularity: 50.0)
      handler_id = attach_telemetry_handler(self(), [[:cinegraph, :search, :group]])

      result = Search.global("wong kar")

      assert Enum.any?(result.people, &(&1.name == "Wong Kar-wai"))

      # Wait for telemetry events from all groups
      assert_receive {:telemetry, [:cinegraph, :search, :group], _, %{group: :people} = meta},
                     500

      assert meta.crashed? == false

      :telemetry.detach(handler_id)
    end

    test "empty groups return [] (not nil) and other groups still populate" do
      # No movies, lists, or companies match — only one person.
      insert_person!("Greta Z. Unique", 700_002, popularity: 99.0)

      result = Search.global("greta z. unique")

      assert result.films == []
      assert result.lists == []
      assert result.companies == []
      assert is_list(result.people) and result.people != []
    end

    test "second call with the same query is a cache hit" do
      insert_person!("Cacheable Cassidy", 700_003, popularity: 10.0)

      handler_id = attach_telemetry_handler(self(), [[:cinegraph, :search, :global]])

      _ = Search.global("cacheable cassidy")
      assert_receive {:telemetry, [:cinegraph, :search, :global], _, meta1}, 500
      assert meta1.cache_hit? == false

      _ = Search.global("cacheable cassidy")
      assert_receive {:telemetry, [:cinegraph, :search, :global], _, meta2}, 500
      assert meta2.cache_hit? == true

      :telemetry.detach(handler_id)
    end

    test "result rows have the documented map shape per group" do
      movie = insert_movie!("Shape Test Movie", ~D[2024-06-01])
      _person = insert_person!("Shape Test Person", 700_004, popularity: 5.0)
      _list = insert_movie_list!("Shape Test List")
      _company = insert_company!("Shape Test Company")

      result = Search.global("shape test")

      assert [%{id: _, tmdb_id: _, title: _, slug: _, poster_path: _, year: _, director: _} | _] =
               result.films

      assert [
               %{id: _, tmdb_id: _, name: _, slug: _, profile_path: _, known_for_department: _}
               | _
             ] =
               result.people

      assert [%{id: _, name: _, slug: _, short_name: _, icon: _} | _] = result.lists

      assert [%{id: _, tmdb_id: _, name: _, logo_path: _, origin_country: _} | _] =
               result.companies

      assert hd(result.films).id == movie.id
    end

    test "person rows preserve nil slug for route fallback" do
      person =
        insert_person!("Nil Slug Search Person", 700_005, popularity: 5.0)
        |> Ecto.Changeset.change(slug: nil)
        |> Repo.update!()

      result = Search.global("nil slug search")

      assert [%{id: id, slug: nil} | _] = result.people
      assert id == person.id
    end
  end

  describe "normalize_query/1" do
    test "lowercases, trims, and collapses whitespace" do
      assert Search.normalize_query("  THE  GodFather  ") == "the godfather"
    end

    test "handles nil" do
      assert Search.normalize_query(nil) == ""
    end
  end

  # ----------------------------------------------------------------------
  # Fixtures
  # ----------------------------------------------------------------------

  defp insert_movie!(title, release_date) do
    tmdb_id = System.unique_integer([:positive])

    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: tmdb_id,
      title: title,
      original_title: title,
      release_date: release_date
    })
    |> Repo.insert!()
  end

  defp insert_person!(name, tmdb_id, opts) do
    popularity = Keyword.get(opts, :popularity, 1.0)

    %Person{}
    |> Person.changeset(%{
      name: name,
      tmdb_id: tmdb_id,
      popularity: popularity,
      known_for_department: "Acting"
    })
    |> Repo.insert!()
  end

  defp insert_movie_list!(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    %MovieList{}
    |> MovieList.changeset(%{
      source_key: "test-#{System.unique_integer([:positive])}",
      name: name,
      slug: slug,
      active: true,
      source_type: "custom",
      source_url: "https://example.test/list",
      category: "curated"
    })
    |> Repo.insert!()
  end

  defp insert_company!(name) do
    %ProductionCompany{}
    |> ProductionCompany.changeset(%{
      name: name,
      tmdb_id: System.unique_integer([:positive])
    })
    |> Repo.insert!()
  end

  # ----------------------------------------------------------------------
  # Telemetry helpers
  # ----------------------------------------------------------------------

  defp attach_telemetry_handler(test_pid, events) do
    handler_id = "test-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    handler_id
  end
end
