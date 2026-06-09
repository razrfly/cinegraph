defmodule Cinegraph.Health.Drift.MoviesTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.Drift
  alias Cinegraph.Movies.{ExternalMetric, Movie}
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  describe "missing_omdb/0 (#1090 — terminal-state predicate, canonical-list scope)" do
    test "counts canonical movies with no blob and no recent fetch attempt; excludes blob-present and tried" do
      # COUNTS: canonical, has imdb_id, no omdb_data blob, no fetch attempt (genuinely needs a fetch)
      _needs_fetch = insert_movie!(canonical: true, imdb_id: "tt1001")

      # NOT counted (the #1090 fix): canonical, blob PRESENT but NO source='omdb' row (sparse
      # response — imdbRating only). The old predicate wrongly counted this as "missing".
      sparse = insert_movie!(canonical: true, imdb_id: "tt1002")
      set_omdb_data!(sparse, %{"Response" => "True", "imdbRating" => "7.4"})
      insert_metric!(sparse, "imdb", "rating_average")

      # NOT counted: canonical, no blob but a recent fetch_attempt (tried, source-absent)
      tried = insert_movie!(canonical: true, imdb_id: "tt1003")
      insert_metric!(tried, "omdb", "fetch_attempt")

      # NOT counted (eligibility): canonical, no blob/attempt, but NO imdb_id — OMDb-ineligible,
      # so it belongs to missing_imdb_id only, not here (P1 regression — was double-counted).
      _no_imdb = insert_movie!(canonical: true, imdb_id: nil)

      # NOT counted: not canonical (out of scope)
      _excluded_non_canonical = insert_movie!(canonical: false)

      result = Drift.Movies.missing_omdb()

      assert result.check == :missing_omdb
      assert result.blocked_reason == nil
      assert result.affected_count == 1
      # canonical-list scope = the 4 canonical movies (non-canonical excluded)
      assert result.total_population == 4
    end

    test "delegates to ratings.omdb_null_backlog with the same scope" do
      _missing = insert_movie!(canonical: true, imdb_id: "tt2001")
      _excluded_non_canonical = insert_movie!(canonical: false)

      ratings_result = Drift.Ratings.omdb_null_backlog()

      assert ratings_result.domain == :ratings
      assert ratings_result.check == :omdb_null_backlog
      assert ratings_result.affected_count == 1
      assert ratings_result.total_population == 1
    end
  end

  describe "missing_imdb_id/0 (#896 Phase 1.3 — canonical-list scope)" do
    test "counts only canonical-list movies missing imdb_id" do
      # Should count: canonical, no imdb_id
      _missing = insert_movie!(canonical: true, imdb_id: nil)

      # Should count: canonical, blank imdb_id
      _blank = insert_movie!(canonical: true, imdb_id: "")

      # Should NOT count: not canonical (out of scope)
      _excluded_non_canonical = insert_movie!(canonical: false, imdb_id: nil)

      # Should NOT count: canonical with valid imdb_id
      _excluded_has_id = insert_movie!(canonical: true, imdb_id: "tt0111161")

      result = Drift.Movies.missing_imdb_id()

      assert result.check == :missing_imdb_id
      assert result.blocked_reason == nil
      assert result.affected_count == 2
      assert result.total_population == 3
    end
  end

  defp insert_movie!(opts) do
    canonical = Keyword.get(opts, :canonical, false)
    canonical_sources = if canonical, do: %{"1001_movies" => %{"included" => true}}, else: %{}

    attrs =
      %{
        tmdb_id: System.unique_integer([:positive]),
        title: "Movie #{System.unique_integer([:positive])}",
        canonical_sources: canonical_sources
      }
      |> Map.merge(Map.new(Keyword.take(opts, [:imdb_id])))

    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_metric!(movie, source, metric_type) do
    %ExternalMetric{}
    |> ExternalMetric.changeset(%{
      movie_id: movie.id,
      source: source,
      metric_type: metric_type,
      value: 75.0,
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp set_omdb_data!(movie, blob) do
    movie |> Ecto.Changeset.change(omdb_data: blob) |> Repo.update!()
  end
end
