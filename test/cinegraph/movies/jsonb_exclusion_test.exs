defmodule Cinegraph.Movies.JsonbExclusionTest do
  @moduledoc """
  #913 PR B regression guards: every list-query leaf that returns `%Movie{}`
  structs must nil out `tmdb_data` and `omdb_data` on the result projection.
  Multi-MB JSONB blobs loaded into the BEAM heap were the OOM driver.

  PR A (#918, #919) already moved every display read off these fields, so
  nilling them on list results is a no-op for the UI.
  """

  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies
  alias Cinegraph.Movies.{DiscoveryRankings, Movie}
  alias Cinegraph.Movies.Query.Params

  describe "Movies list-query JSONB exclusion (#913 PR B)" do
    test "list_movies/1 returns Movie structs with tmdb_data and omdb_data nilled" do
      insert_movie_with_blobs!("List Movies Blob")

      [movie | _] = Movies.list_movies()

      assert %Movie{} = movie
      assert movie.tmdb_data == nil
      assert movie.omdb_data == nil
      # First-class columns must still be populated.
      assert is_binary(movie.title)
      assert is_integer(movie.tmdb_id)
    end

    test "recent_theatrical_releases/1 inherits the slim projection from feature_film_query/0" do
      today = Date.utc_today()

      insert_movie_with_blobs!("Recent Theatrical Blob",
        release_date: Date.add(today, -7)
      )

      movies = Movies.recent_theatrical_releases(today: today, days: 30, limit: 5)

      assert length(movies) > 0

      for movie <- movies do
        assert %Movie{} = movie
        assert movie.tmdb_data == nil
        assert movie.omdb_data == nil
      end
    end

    test "list_canonical_shelf_movies/2 nils JSONB on shelf results" do
      key = "test_shelf_#{System.unique_integer([:positive])}"

      insert_movie_with_blobs!("Canonical Shelf Blob",
        canonical_sources: %{key => %{"list_position" => "1"}}
      )

      [movie | _] = Movies.list_canonical_shelf_movies(key, 5)

      assert %Movie{} = movie
      assert movie.tmdb_data == nil
      assert movie.omdb_data == nil
    end

    test "list_soft_imports/1 nils JSONB on soft-import results" do
      insert_movie_with_blobs!("Soft Import Blob", import_status: "soft")

      [movie | _] = Movies.list_soft_imports()

      assert %Movie{} = movie
      assert movie.tmdb_data == nil
      assert movie.omdb_data == nil
    end

    test "feature_film_query/0 base inheritance — composed queries inherit the slim projection" do
      import Ecto.Query

      insert_movie_with_blobs!("Feature Film Inheritance Blob")

      # Compose a custom query on top of feature_film_query/0 — the
      # select_merge baked into the base must carry forward.
      movies =
        Movies.feature_film_query()
        |> limit(5)
        |> Cinegraph.Repo.all()

      assert length(movies) > 0

      for movie <- movies do
        assert %Movie{} = movie
        assert movie.tmdb_data == nil
        assert movie.omdb_data == nil
      end
    end
  end

  describe "DiscoveryRankings.list_default/1 JSONB exclusion (#913 PR B — hottest path)" do
    # The MV is created empty by migration and refreshed by an Oban worker in
    # prod. In tests we refresh inline (non-concurrently) so the MV picks up
    # the row we just inserted. Non-concurrent REFRESH runs inside the sandbox
    # transaction and rolls back with it — no cross-test pollution.
    test "result rows have tmdb_data and omdb_data nilled (regression guard for the OOM path)" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      movie =
        insert_movie_with_blobs!("Discovery Default Blob",
          # release_date must be ≤ CURRENT_DATE so the MV's is_released = true.
          release_date: ~D[2024-01-01]
        )

      # The MV's metric_pivot CTE looks for source="tmdb" rows at these three
      # metric_types. Seed one so the movie has a non-NULL discovery score
      # and rises above any stale rows that may exist in the shared schema.
      Repo.insert_all(Cinegraph.Movies.ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "rating_votes",
          value: 50_000.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "rating_average",
          value: 8.5,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "popularity_score",
          value: 250.0,
          fetched_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

      Ecto.Adapters.SQL.query!(Repo, "REFRESH MATERIALIZED VIEW movie_discovery_rankings_mv")

      params = %Params{sort: "discovery_score_desc", per_page: 50}
      assert {:ok, {movies, _meta}} = DiscoveryRankings.list_default(params)

      hit = Enum.find(movies, &(&1.id == movie.id))
      assert hit, "inserted movie should appear in the default browse path"

      assert %Movie{} = hit
      assert hit.tmdb_data == nil
      assert hit.omdb_data == nil
      assert hit.title == "Discovery Default Blob"
    end
  end

  # Helpers — keep self-contained so the file isn't coupled to other test
  # fixtures. The JSONB blobs we insert are sentinel maps that prove the
  # select_merge nilled the column (not that the column was empty to begin
  # with).
  defp insert_movie_with_blobs!(title, attrs \\ []) do
    base = %{
      tmdb_id: System.unique_integer([:positive]),
      title: title,
      original_title: title,
      release_date: ~D[2024-01-01],
      tmdb_data: %{"vote_average" => 7.5, "marker" => "pr-b-must-be-nilled"},
      omdb_data: %{"imdbRating" => "8.0", "marker" => "pr-b-must-be-nilled"},
      import_status: Keyword.get(attrs, :import_status, "full"),
      adult: false,
      runtime: 120
    }

    attrs_map =
      attrs
      |> Keyword.drop([:import_status])
      |> Enum.into(%{})

    %Movie{}
    |> Movie.changeset(Map.merge(base, attrs_map))
    |> Repo.insert!()
  end
end
