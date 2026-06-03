defmodule Cinegraph.Predictions.SweepTest do
  # Runs in the standard Ecto sandbox (no external services), like trainer_test.exs: the top-level
  # tests assert graceful behavior against an empty DB, and the seeded `describe` below exercises
  # the candidate-universe temporal validation (#1045) on planted data. Full-scale determinism +
  # PR-AUC ranking on the real catalog are validated live by `mix predictions.experiment --sweep`.
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.Trainer
  alias Cinegraph.Repo

  test "run_experiment errors cleanly for a list with no temporal spread" do
    assert Trainer.run_experiment("nonexistent_list_xyz", granularity: :data_point) in [
             {:error, :insufficient_decades},
             {:error, :no_data_point_features}
           ]
  end

  test "run_sweep drops failed variants and returns a (here empty) ranked list, never crashing" do
    variants = [[features: :raw, sample_ratio: 5], [features: :all, sample_ratio: 5]]
    assert Trainer.run_sweep("nonexistent_list_xyz", variants, max_concurrency: 2) == []
  end

  describe "candidate-universe temporal validation (#1045)" do
    @list "sweep_test_list"

    setup do
      CatalogSeed.seed!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all("movie_lists", [
        %{
          name: "Sweep Test List",
          source_key: @list,
          source_type: "imdb",
          source_url: "https://example.com/#{@list}",
          category: "test",
          slug: @list,
          active: true,
          inserted_at: now,
          updated_at: now
        }
      ])

      # Three decades so the split yields train (1990) / validation (2000) / holdout (2010).
      for {decade, n_members, n_others} <- [{1990, 6, 16}, {2000, 5, 14}, {2010, 5, 14}] do
        for i <- 1..n_members, do: plant(decade, i, member: true)
        for i <- 1..n_others, do: plant(decade, 100 + i, member: false)
      end

      :ok
    end

    test "scores a decade-scoped universe (positives + voted negatives), excluding the holdout" do
      assert {:ok, r} =
               Trainer.run_experiment(@list, granularity: :data_point, min_val_positives: 1)

      # Deterministic 3-way split: validation is the decade just before the sacred holdout.
      assert r.train_decades == [1990]
      assert r.validation_decades == [2000]
      assert r.holdout_decades == [2010]

      # The universe is the 2000-decade members (5) + the most-voted 2000-decade non-members (14).
      # 2010 (holdout) and 1990 (train) movies are NOT scored — proves the decade scoping.
      assert r.metrics["n_evaluated"] == 19
      assert r.metrics["n_positives"] == 5
      assert r.validation_universe == %{"positives" => 5, "negatives" => 14, "min_votes" => 1000}

      assert r.backtest_strategy == "temporal-validation"
      assert is_map(r.metrics["baselines"])
    end

    test "run_sweep applies the shared universe to every variant" do
      ranked =
        Trainer.run_sweep(@list, [[features: :all], [features: :raw]], min_val_positives: 1)

      assert length(ranked) == 2
      assert Enum.all?(ranked, fn r -> r.metrics["n_evaluated"] == 19 end)
    end
  end

  # ── fixtures (mirrors trainer_test.exs) ──────────────────────────────────────────

  defp plant(decade, i, member: member?) do
    canonical = if member?, do: %{@list => true}, else: %{}

    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "#{decade} #{i}",
        release_date: Date.new!(decade + rem(i, 9), 6, 1),
        import_status: "full",
        canonical_sources: canonical
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    imdb = if member?, do: 8.5, else: 5.5
    pop = if member?, do: 80.0, else: 20.0

    Repo.insert_all("external_metrics", [
      ext(movie.id, "imdb", "rating_average", imdb, now),
      ext(movie.id, "tmdb", "popularity_score", pop, now),
      # ≥ the universe min-votes floor so non-members enter the candidate pool
      ext(movie.id, "tmdb", "rating_votes", 1500.0, now)
    ])

    movie
  end

  defp ext(movie_id, source, metric_type, value, now) do
    %{
      movie_id: movie_id,
      source: source,
      metric_type: metric_type,
      value: value,
      fetched_at: now,
      inserted_at: now,
      updated_at: now
    }
  end
end
