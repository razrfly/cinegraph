defmodule Cinegraph.Health.Drift.MoviesTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.Drift
  alias Cinegraph.Movies.{ExternalMetric, Movie}
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  describe "missing_omdb/0 (#896 Phase 1.2 — canonical-list scope)" do
    test "counts only canonical-list movies with no external_metrics row for omdb" do
      # Should count: canonical, no OMDb fetch recorded
      _missing = insert_movie!(canonical: true)

      # Should NOT count: not canonical (out of scope)
      _excluded_non_canonical = insert_movie!(canonical: false)

      # Should NOT count: canonical but has OMDb fetch
      with_omdb = insert_movie!(canonical: true)
      insert_metric!(with_omdb, "omdb", "rating_average")

      result = Drift.Movies.missing_omdb()

      assert result.check == :missing_omdb
      assert result.blocked_reason == nil
      assert result.affected_count == 1
      # Total reflects the canonical-list scope, not the full movies table
      assert result.total_population == 2
    end

    test "delegates to ratings.omdb_null_backlog with the same scope" do
      _missing = insert_movie!(canonical: true)
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
end
