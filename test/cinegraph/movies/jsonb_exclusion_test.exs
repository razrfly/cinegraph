defmodule Cinegraph.Movies.JsonbExclusionTest do
  @moduledoc """
  #913 / #923 regression guards: every `%Movie{}` loaded from a default
  `from m in Movie` query must have `tmdb_data` and `omdb_data` come back
  as `nil` — not because we overlay nil after the load (that was the
  no-op #920 mechanism), but because the schema marks those fields
  `load_in_query: false` and Ecto omits them from the SELECT entirely.

  PR A (#918, #919) already moved every display read off these fields, so
  the columns being absent on list results is a no-op for the UI.
  """

  use Cinegraph.DataCase, async: false

  import Ecto.Query

  alias Cinegraph.Movies
  alias Cinegraph.Movies.{DiscoveryRankings, Movie}
  alias Cinegraph.Movies.Query.Params

  describe "SQL-level JSONB exclusion (#923 — proves the fix isn't a no-op)" do
    # PR #920's `select_merge: %{m | tmdb_data: nil}` mechanism passed every
    # functional test by setting the BEAM field to nil after load. It did
    # nothing for the OOM because Postgres still shipped the bytes. These
    # tests pin that the columns are absent from the SQL itself.

    test "default Movie SELECT omits tmdb_data and omdb_data" do
      {sql, _} = Repo.to_sql(:all, from(m in Movie))
      refute sql =~ ~s("tmdb_data"), "tmdb_data must not appear in default SELECT"
      refute sql =~ ~s("omdb_data"), "omdb_data must not appear in default SELECT"
    end

    test "explicit select_merge can opt back in to tmdb_data" do
      {sql, _} =
        Repo.to_sql(:all, from(m in Movie, select_merge: %{tmdb_data: m.tmdb_data}))

      assert sql =~ ~s("tmdb_data"), "explicit opt-in must still emit tmdb_data in SELECT"
    end
  end

  describe "Movies list-query JSONB exclusion (#923)" do
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
      insert_movie_with_blobs!("Feature Film Inheritance Blob")

      # Compose a custom query on top of feature_film_query/0 — the
      # schema-level load_in_query: false must carry forward.
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

  describe "OMDb processor opts in to omdb_data (#923 — re-audit P1 regression guard)" do
    # Re-audit of #924 caught: OMDbEnrichmentWorker did
    # `movie = Movies.get_movie!(movie_id); if movie.omdb_data && !force`,
    # but with load_in_query: false on the schema field that guard ALWAYS sees
    # nil and re-calls the OMDb API for every job. The worker now delegates
    # the skip decision to OMDb.process_movie/2, whose `get_movie/1` opts back
    # in to omdb_data via select_merge. This test pins that opt-in: if the
    # select_merge regresses, this test hits the OMDb client which raises
    # "OMDB_API_KEY not configured" in the test env.
    test "OMDb.process_movie/2 skips already-enriched movie via inner guard" do
      imdb_id = "tt#{:rand.uniform(89_999_999) + 10_000_000}"

      movie =
        insert_movie_with_blobs!("OMDb Skip Blob",
          imdb_id: imdb_id
        )

      now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      now_utc = DateTime.utc_now() |> DateTime.truncate(:second)

      # #1053: should_skip_processing? now keys on the blob alone (has_data?/1).
      # The external_metrics row below is no longer required for the skip, but is
      # kept so this test still reproduces the original #923 enriched-movie
      # scenario (blob + metrics present) and pins the select_merge opt-in.
      Repo.insert_all(Cinegraph.Movies.ExternalMetric, [
        %{
          movie_id: movie.id,
          source: "omdb",
          metric_type: "rating_average",
          value: 8.5,
          fetched_at: now_utc,
          inserted_at: now_naive,
          updated_at: now_naive
        }
      ])

      # Capture pre-call state. If the skip path doesn't trigger,
      # OMDb.Client.get_movie_by_imdb_id raises ("OMDB_API_KEY not configured"
      # in test env) AND/OR new external_metrics rows are written.
      metrics_before = Repo.aggregate(Cinegraph.Movies.ExternalMetric, :count, :id)
      reloaded_before = Repo.get!(Movie, movie.id)

      assert {:ok, returned} = Cinegraph.ApiProcessors.OMDb.process_movie(movie.id)

      # Skip path returns the loaded movie. With select_merge in get_movie/1,
      # the opt-in omdb_data must survive the load — if it doesn't, the bug
      # this test guards against is back.
      assert returned.id == movie.id
      assert returned.omdb_data["marker"] == "pr-b-must-be-nilled"

      metrics_after = Repo.aggregate(Cinegraph.Movies.ExternalMetric, :count, :id)
      reloaded_after = Repo.get!(Movie, movie.id)

      assert metrics_after == metrics_before,
             "skip path must not insert external_metrics rows"

      assert reloaded_after.updated_at == reloaded_before.updated_at,
             "skip path must not update the movie row"
    end
  end

  describe "Predictions box_office sources external-metrics, not the tmdb_data blob (#1042)" do
    # #1042 moved Target-mode box_office's budget/revenue read from the load_in_query:false
    # `tmdb_data` blob to the catalogued external-metrics (`tmdb_budget`/`tmdb_revenue_worldwide`).
    # So get_movie_scoring_details no longer opts the blob back in. Guard: the blob is NOT
    # loaded, yet box_office still reflects financials (from the substrate) rather than zeroing.
    test "get_movie_scoring_details/1 reads box_office from external-metrics without loading tmdb_data" do
      movie = insert_movie_with_blobs!("Predictions Detail Blob")
      now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      now_utc = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(Cinegraph.Movies.ExternalMetric, [
        ext_metric(movie.id, "budget", 10_000_000.0, now_utc, now_naive),
        ext_metric(movie.id, "revenue_worldwide", 500_000_000.0, now_utc, now_naive)
      ])

      details = Cinegraph.Predictions.MoviePredictor.get_movie_scoring_details(movie.id)

      assert %Movie{} = details.movie
      assert details.movie.id == movie.id
      # #1042: the load_in_query:false blob is no longer opted back in for scoring.
      assert is_nil(details.movie.tmdb_data)

      # box_office still reflects budget/revenue — from external_metrics, not a 0 from the absent blob.
      assert details.prediction.criteria_scores.box_office > 0
    end
  end

  describe "DiscoveryRankings.list_default/1 JSONB exclusion (#923 — hottest path)" do
    # The MV is created empty by migration and refreshed by an Oban worker in
    # prod. In tests we refresh inline (non-concurrently) so the MV picks up
    # the row we just inserted. Non-concurrent REFRESH runs inside the sandbox
    # transaction and rolls back with it — no cross-test pollution.
    test "result rows have tmdb_data and omdb_data nilled (regression guard for the OOM path)" do
      now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      now_utc = DateTime.utc_now() |> DateTime.truncate(:second)

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
          fetched_at: now_utc,
          inserted_at: now_naive,
          updated_at: now_naive
        },
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "rating_average",
          value: 8.5,
          fetched_at: now_utc,
          inserted_at: now_naive,
          updated_at: now_naive
        },
        %{
          movie_id: movie.id,
          source: "tmdb",
          metric_type: "popularity_score",
          value: 250.0,
          fetched_at: now_utc,
          inserted_at: now_naive,
          updated_at: now_naive
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

  defp ext_metric(movie_id, metric_type, value, now_utc, now_naive) do
    %{
      movie_id: movie_id,
      source: "tmdb",
      metric_type: metric_type,
      value: value,
      fetched_at: now_utc,
      inserted_at: now_naive,
      updated_at: now_naive
    }
  end
end
