defmodule Cinegraph.Health.Drift.RatingsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.Drift
  alias Cinegraph.Movies.{ExternalMetric, Movie}
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  describe "rt_metacritic_gap/0 (#735 Phase 1.3 — canonical-list scope)" do
    test "counts only canonical-list movies missing both RT and MC" do
      # Should count: canonical, no RT, no MC
      _missing_both = insert_movie!(canonical: true)

      # Should NOT count: not canonical (out of scope)
      _excluded_non_canonical = insert_movie!(canonical: false)

      # Should NOT count: canonical but has RT
      with_rt = insert_movie!(canonical: true)
      insert_metric!(with_rt, "rotten_tomatoes", "tomatometer")

      # Should NOT count: canonical but has MC
      with_mc = insert_movie!(canonical: true)
      insert_metric!(with_mc, "metacritic", "metascore")

      result = Drift.Ratings.rt_metacritic_gap()

      assert result.check == :rt_metacritic_gap
      assert result.blocked_reason == nil
      assert result.affected_count == 1
      # Total reflects the canonical-list scope, not the full catalog
      assert result.total_population == 3
    end
  end

  defp insert_movie!(opts) do
    canonical = Keyword.get(opts, :canonical, false)
    canonical_sources = if canonical, do: %{"1001_movies" => %{"included" => true}}, else: %{}

    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "Movie #{System.unique_integer([:positive])}",
      canonical_sources: canonical_sources
    })
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
