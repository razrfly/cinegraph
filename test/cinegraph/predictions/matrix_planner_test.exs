defmodule Cinegraph.Predictions.MatrixPlannerTest do
  @moduledoc """
  The `--plan` planner (#1065 Phase 2): the planner-generated grid honors per-cell vs pooled
  fan-out, the count provably matches a real `run_matrix` (no drift), and the pool-weighted ETA is
  built from `duration_ms` history with no-history shapes flagged rather than silently zeroed.
  """
  use Cinegraph.DataCase
  import Ecto.Query

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.{ExperimentLedger, MatrixPlanner, Trainer}
  alias Cinegraph.Repo

  @list "planner_test_list"

  # ── plan/1 grid (pure, no DB needed when lists are given) ─────────────────────────
  describe "plan/1 — planner-generated cell grid" do
    test "per-cell fan-out = lists × classes × strategies × buckets × variants" do
      plan =
        MatrixPlanner.plan(
          lists: ["a", "b"],
          classes: ["linear_logreg"],
          strategies: ["temporal", "static"],
          buckets: [:objective_only, :all]
        )

      assert length(plan.per_cell) == 2 * 1 * 2 * 2
      assert plan.pooled == []
      assert plan.total == 8
    end

    test "pooled fan-out = one eval per list (objective_only/temporal), ignoring strat/bucket grid" do
      plan =
        MatrixPlanner.plan(
          lists: ["a", "b", "c"],
          classes: ["pooled_linear"],
          strategies: ["temporal", "static"],
          buckets: [:objective_only, :all]
        )

      assert plan.per_cell == []
      assert length(plan.pooled) == 3

      assert Enum.all?(
               plan.pooled,
               &(&1.strategy == "temporal" and &1.feature_bucket == :objective_only)
             )
    end

    test "mixed classes combine: per-cell 8 + pooled 2 = 10" do
      plan =
        MatrixPlanner.plan(
          lists: ["a", "b"],
          classes: ["linear_logreg", "pooled_linear"],
          strategies: ["temporal", "static"],
          buckets: [:objective_only, :all]
        )

      assert length(plan.per_cell) == 8
      assert length(plan.pooled) == 2
      assert plan.total == 10

      by_class = Map.new(plan.by_class, &{&1.class, &1})
      assert by_class["linear_logreg"].kind == :per_cell
      assert by_class["pooled_linear"].kind == :pooled
    end
  end

  # ── count parity: plan == what a real run executes ────────────────────────────────
  describe "plan count matches a real run (no drift)" do
    setup do
      seed_data()
      :ok
    end

    test "per-cell plan count equals the rows run_matrix persists" do
      opts = [
        lists: [@list],
        classes: ["linear_logreg"],
        strategies: ["temporal", "static"],
        buckets: [:objective_only, :all],
        max_concurrency: 2
      ]

      plan = MatrixPlanner.plan(opts)
      Trainer.run_matrix(opts)

      persisted =
        Repo.aggregate(
          from(e in ExperimentLedger, where: e.model_class == "linear_logreg"),
          :count
        )

      assert length(plan.per_cell) == 4
      assert persisted == length(plan.per_cell)
    end
  end

  # ── estimate/2 — pool-weighted ETA from history ───────────────────────────────────
  describe "estimate/2" do
    test "empty ledger flags every shape as no_history and yields eta 0 (never bogus)" do
      plan =
        MatrixPlanner.plan(
          lists: ["a"],
          classes: ["linear_logreg"],
          strategies: ["temporal"],
          buckets: [:all]
        )

      est = MatrixPlanner.estimate(plan)

      assert est.basis_count == 0
      assert est.eta_ms == 0
      assert length(est.no_history) == length(plan.cells)
    end

    test "with history, matched shapes leave no_history and ETA is the median over concurrency" do
      insert_hist("a", "temporal", "all", 10_000)
      insert_hist("a", "temporal", "all", 20_000)

      plan =
        MatrixPlanner.plan(
          lists: ["a"],
          classes: ["linear_logreg"],
          strategies: ["temporal"],
          buckets: [:all]
        )

      est = MatrixPlanner.estimate(plan, max_concurrency: 1)

      assert est.basis_count == 2
      assert est.no_history == []
      # one cell, median of [10k, 20k] = 15k, concurrency 1.
      assert est.eta_ms == 15_000
    end

    test "fits duration ≈ k · n_evaluated and prices an unseen shape by its estimated pool size" do
      # A clean linear cost: 1ms per movie scored, no intercept.
      insert_hist("trained", "static", "all", 1_000, 1_000)
      insert_hist("trained", "static", "all", 2_000, 2_000)
      insert_hist("trained", "static", "all", 3_000, 3_000)

      # A brand-new list/shape with NO duration history of its own → priced by the fitted model from
      # the (static, all) pool size it inherits.
      plan =
        MatrixPlanner.plan(
          lists: ["unseen"],
          classes: ["linear_logreg"],
          strategies: ["static"],
          buckets: [:all]
        )

      est = MatrixPlanner.estimate(plan, max_concurrency: 1)

      assert %{k: k, r2: r2, n: 3} = est.cost_model
      assert_in_delta k, 1.0, 0.0001
      assert_in_delta r2, 1.0, 0.0001
      assert est.no_history == []
      # pool for (static, all) = median(1000,2000,3000) = 2000 → predicted ≈ 1.0 · 2000.
      assert est.eta_ms == 2_000
    end

    test "reports a stated error band (rel_err): near-zero for clean linear history" do
      for {n, d} <- [{1_000, 1_000}, {2_000, 2_000}, {3_000, 3_000}, {4_000, 4_000}],
          do: insert_hist("c", "static", "all", d, n)

      cm = MatrixPlanner.cost_model()
      assert cm.rel_err < 0.01
      assert cm.r2 > 0.99
    end

    test "the error band widens for noisy history (so the ETA's ± is honest)" do
      for {n, d} <- [
            {1_000, 1_400},
            {2_000, 1_500},
            {3_000, 3_500},
            {4_000, 3_400},
            {5_000, 5_600}
          ],
          do: insert_hist("c", "static", "all", d, n)

      cm = MatrixPlanner.cost_model()
      assert cm.rel_err > 0.05
    end

    test "falls back from (source_key, strategy, bucket) to (strategy, bucket) for a new list" do
      insert_hist("known_list", "static", "all", 30_000)

      plan =
        MatrixPlanner.plan(
          lists: ["brand_new_list"],
          classes: ["linear_logreg"],
          strategies: ["static"],
          buckets: [:all]
        )

      est = MatrixPlanner.estimate(plan, max_concurrency: 1)

      # No history for brand_new_list itself, but the (static, all) shape exists → still estimated.
      assert est.no_history == []
      assert est.eta_ms == 30_000
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────────────

  defp insert_hist(source_key, strategy, bucket, duration_ms, n_evaluated \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ExperimentLedger{}
    |> ExperimentLedger.changeset(%{
      source_key: source_key,
      model_class: "linear_logreg",
      backtest_strategy: strategy,
      granularity: "data_point",
      feature_bucket: bucket,
      status: "ok",
      grade: "low",
      duration_ms: duration_ms,
      n_evaluated: n_evaluated,
      run_at: now
    })
    |> Repo.insert!()
  end

  defp seed_data do
    CatalogSeed.seed!()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("movie_lists", [
      %{
        name: @list,
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

    for {decade, n_members, n_others} <- [{1980, 8, 20}, {1990, 8, 20}, {2000, 10, 24}] do
      for i <- 1..n_members, do: plant(decade, i, true)
      for i <- 1..n_others, do: plant(decade, 100 + i, false)
    end

    :ok
  end

  defp plant(decade, i, member?) do
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
    pop = if member?, do: 30.0, else: 50.0

    Repo.insert_all("external_metrics", [
      ext(movie.id, "imdb", "rating_average", imdb, now),
      ext(movie.id, "tmdb", "popularity_score", pop, now),
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
