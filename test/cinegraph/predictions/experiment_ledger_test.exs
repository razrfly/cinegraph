# Fake model classes (#1061 PR1) to prove model_class actually CONTROLS the fit, and that a fit
# exception still records a `failed` ledger row.
defmodule Cinegraph.Predictions.SentinelClass do
  @behaviour Cinegraph.Predictions.ModelClass
  @impl true
  def key, do: "sentinel"
  @impl true
  def label, do: "Sentinel"
  @impl true
  def serving_kind, do: :weight_map
  @impl true
  def fit(_x, _y, _codes, _opts), do: {:ok, %{"sentinel" => 1.0}}
  @impl true
  def score(w, g, sk), do: {g, w, sk}
  @impl true
  def serialize(w), do: w
  @impl true
  def load(w), do: w
  @impl true
  def explain(w), do: w
end

defmodule Cinegraph.Predictions.BoomClass do
  @behaviour Cinegraph.Predictions.ModelClass
  @impl true
  def key, do: "boom"
  @impl true
  def label, do: "Boom"
  @impl true
  def serving_kind, do: :weight_map
  @impl true
  def fit(_x, _y, _codes, _opts), do: raise("boom during fit")
  @impl true
  def score(w, g, sk), do: {g, w, sk}
  @impl true
  def serialize(w), do: w
  @impl true
  def load(w), do: w
  @impl true
  def explain(w), do: w
end

defmodule Cinegraph.Predictions.ExperimentLedgerTest do
  @moduledoc """
  The experiment ledger + the single-writer `Trainer.evaluate_cell`/`run_cells` (#1061 Session 1):
  changeset validations, the normalized report shape for BOTH strategies, the persist?: gate
  (0 rows by default, exactly 1 when persisting, 1 failed row on error), no double-write across a
  multi-cell run, and the leaderboard ranking key (objective full-pool recall, COALESCE fallback).
  """
  use Cinegraph.DataCase
  import Ecto.Query

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.{ExperimentLedger, Trainer}
  alias Cinegraph.Repo

  @list "ledger_test_list"
  @empty_list "ledger_empty_list"

  setup do
    CatalogSeed.seed!()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("movie_lists", [
      list_row(@list, now),
      list_row(@empty_list, now)
    ])

    # Three decades so the temporal split (train/val/holdout, needs ≥3) is valid AND static works.
    for {decade, n_members, n_others} <- [{1980, 8, 20}, {1990, 8, 20}, {2000, 10, 24}] do
      for i <- 1..n_members, do: plant(decade, i, member: true)
      for i <- 1..n_others, do: plant(decade, 100 + i, member: false)
    end

    :ok
  end

  defp list_row(key, now) do
    %{
      name: key,
      source_key: key,
      source_type: "imdb",
      source_url: "https://example.com/#{key}",
      category: "test",
      slug: key,
      active: true,
      inserted_at: now,
      updated_at: now
    }
  end

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

  # ── changeset ─────────────────────────────────────────────────────────────────
  describe "ExperimentLedger.changeset/2" do
    @valid %{
      source_key: @list,
      model_class: "linear_logreg",
      backtest_strategy: "temporal",
      granularity: "data_point",
      status: "ok"
    }

    test "valid with the required fields" do
      assert ExperimentLedger.changeset(%ExperimentLedger{}, @valid).valid?
    end

    test "requires source_key/model_class/backtest_strategy/granularity" do
      cs = ExperimentLedger.changeset(%ExperimentLedger{}, %{})
      refute cs.valid?

      # status has a schema default ("ok"), so it isn't blank; the other four are required.
      for f <- [:source_key, :model_class, :backtest_strategy, :granularity],
          do: assert("can't be blank" in (errors_on(cs)[f] || []))
    end

    test "rejects an unknown status" do
      cs = ExperimentLedger.changeset(%ExperimentLedger{}, Map.put(@valid, :status, "weird"))
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :status)
    end

    test "jsonb weights/metrics round-trip and text error persists" do
      row =
        @valid
        |> Map.merge(%{
          status: "failed",
          error: "boom: :insufficient_decades",
          weights: %{"imdb_rating" => 0.7},
          metrics: %{"recall_at_k" => 0.5, "baselines" => %{"popularity" => 0.1}}
        })

      assert {:ok, saved} =
               %ExperimentLedger{} |> ExperimentLedger.changeset(row) |> Repo.insert()

      reloaded = Repo.get!(ExperimentLedger, saved.id)
      assert reloaded.weights == %{"imdb_rating" => 0.7}
      assert reloaded.metrics["baselines"]["popularity"] == 0.1
      assert reloaded.error =~ "insufficient_decades"
    end
  end

  # ── evaluate_cell ───────────────────────────────────────────────────────────────
  describe "evaluate_cell/1 normalization (both strategies)" do
    test "temporal returns a normalized report and writes nothing by default" do
      assert {:ok, row} =
               Trainer.evaluate_cell(
                 source_key: @list,
                 strategy: "temporal",
                 feature_bucket: :all
               )

      assert row.model_class == "linear_logreg"
      assert row.backtest_strategy == "temporal"
      assert row.feature_bucket == "all"
      assert Map.has_key?(row.metrics, "recall_at_k")
      assert Map.has_key?(row.metrics, "objective_recall_at_k")
      assert Map.has_key?(row.metrics, "pr_auc")
      assert is_map(row.weights) and map_size(row.weights) > 0
      # default persist?: false → sandbox stays clean
      assert Repo.aggregate(ExperimentLedger, :count) == 0
    end

    test "static returns the SAME normalized shape (proves the unified report)" do
      assert {:ok, row} =
               Trainer.evaluate_cell(source_key: @list, strategy: "static", feature_bucket: :all)

      assert row.backtest_strategy == "static"
      assert Map.has_key?(row.metrics, "recall_at_k")
      assert Map.has_key?(row.metrics, "objective_recall_at_k")
      assert Map.has_key?(row.metrics, "baselines")
      assert Repo.aggregate(ExperimentLedger, :count) == 0
    end

    test "persist?: true writes exactly one ok row with the cell descriptors" do
      assert {:ok, _row} =
               Trainer.evaluate_cell(
                 source_key: @list,
                 strategy: "static",
                 feature_bucket: :objective_only,
                 persist?: true
               )

      assert [saved] = Repo.all(ExperimentLedger)
      assert saved.source_key == @list
      assert saved.model_class == "linear_logreg"
      assert saved.backtest_strategy == "static"
      assert saved.feature_bucket == "objective_only"
      assert saved.status == "ok"
      assert saved.grade in ~w(high moderate low insufficient)
      assert saved.code_version != nil
      refute saved.holdout_spent
    end

    test "error path records exactly one failed row (no silent drop)" do
      # No members → both strategies error; persist a 'failed' row with the reason.
      assert {:error, _reason} =
               Trainer.evaluate_cell(
                 source_key: @empty_list,
                 strategy: "temporal",
                 persist?: true
               )

      assert [saved] = Repo.all(ExperimentLedger)
      assert saved.status == "failed"
      assert is_binary(saved.error)
      assert saved.source_key == @empty_list
    end
  end

  # ── run_cells (single-writer, no dup) ────────────────────────────────────────────
  describe "run_cells/3" do
    test "writes exactly one row per cell across the 3 ablation buckets" do
      cells = [
        [feature_bucket: :objective_only],
        [feature_bucket: :canon_overlap],
        [feature_bucket: :all]
      ]

      rows = Trainer.run_cells(@list, cells, strategy: "temporal", max_concurrency: 3)

      assert length(rows) == 3
      assert Repo.aggregate(ExperimentLedger, :count) == 3

      buckets = Repo.all(from e in ExperimentLedger, select: e.feature_bucket)
      assert Enum.sort(buckets) == ~w(all canon_overlap objective_only)
    end
  end

  # ── matrix runner (PR2) ──────────────────────────────────────────────────────────
  describe "run_matrix/1" do
    test "records one row per classes × lists × strategies × buckets cell" do
      rows =
        Trainer.run_matrix(
          lists: [@list],
          classes: ["linear_logreg"],
          strategies: ["temporal"],
          buckets: [:objective_only, :all],
          max_concurrency: 2
        )

      assert length(rows) == 2
      assert Repo.aggregate(ExperimentLedger, :count) == 2
      buckets = Repo.all(from e in ExperimentLedger, select: e.feature_bucket)
      assert Enum.sort(buckets) == ~w(all objective_only)
      assert Enum.all?(rows, &(&1.model_class == "linear_logreg"))
    end
  end

  # ── leaderboard ranking key ──────────────────────────────────────────────────────
  describe "leaderboard ranking (objective full-pool recall, COALESCE fallback)" do
    setup do
      insert_row(%{"objective_recall_at_k" => 0.40, "recall_at_k" => 0.9}, "a", "high")
      insert_row(%{"objective_recall_at_k" => 0.60, "recall_at_k" => 0.9}, "b", "high")
      # No objective → ranks on recall_at_k (0.20) via COALESCE.
      insert_row(%{"recall_at_k" => 0.20}, "c", "low")
      :ok
    end

    test "orders by objective recall desc, falling back to recall_at_k" do
      ranked =
        Repo.all(
          from e in ExperimentLedger,
            where: e.status == "ok",
            order_by: [
              desc_nulls_last:
                fragment(
                  "COALESCE((? ->> 'objective_recall_at_k')::float, (? ->> 'recall_at_k')::float)",
                  e.metrics,
                  e.metrics
                )
            ],
            select: e.source_key
        )

      # b (0.60) > a (0.40) > c (0.20 via fallback)
      assert ranked == ["b", "a", "c"]
    end

    test "failed rows are excluded from the board" do
      insert_row(%{"recall_at_k" => 0.99}, "zz", "low", "failed")
      count = Repo.aggregate(from(e in ExperimentLedger, where: e.status == "ok"), :count)
      assert count == 3
    end
  end

  # ── PR1 prereq fixes (#1061 Session 2) ──────────────────────────────────────────
  describe "static feature buckets are honored (PR1 fix 1)" do
    test "objective_only static cell fits objective codes only (not the full surface)" do
      {:ok, obj} =
        Trainer.evaluate_cell(
          source_key: @list,
          strategy: "static",
          feature_bucket: :objective_only
        )

      {:ok, all} =
        Trainer.evaluate_cell(source_key: @list, strategy: "static", feature_bucket: :all)

      # canon-overlap derived code is in :all but stripped from :objective_only…
      assert Map.has_key?(all.weights, "canonical_contribution")
      refute Map.has_key?(obj.weights, "canonical_contribution")
      # …and the other list's membership code (canon-overlap) is absent from objective.
      refute Map.has_key?(obj.weights, @empty_list)
      # genuinely different fits, not the same full-surface model mislabeled.
      refute obj.weights == all.weights
    end
  end

  describe "model_class controls the fit (PR1 fix 2)" do
    setup do
      original = Application.get_env(:cinegraph, :model_classes)

      Application.put_env(:cinegraph, :model_classes, [
        Cinegraph.Predictions.LinearLogReg,
        Cinegraph.Predictions.SentinelClass,
        Cinegraph.Predictions.BoomClass
      ])

      on_exit(fn ->
        if original,
          do: Application.put_env(:cinegraph, :model_classes, original),
          else: Application.delete_env(:cinegraph, :model_classes)
      end)
    end

    test "a registered class's fit produces the ledger weights (not just the label)" do
      {:ok, row} =
        Trainer.evaluate_cell(source_key: @list, strategy: "temporal", model_class: "sentinel")

      assert row.model_class == "sentinel"
      # The sentinel class returns this exact weight map — proves the class drove training.
      assert row.weights == %{"sentinel" => 1.0}
    end

    test "a fit exception is recorded as a failed row, not silently dropped (PR1 fix 3)" do
      assert {:error, _reason} =
               Trainer.evaluate_cell(
                 source_key: @list,
                 strategy: "temporal",
                 model_class: "boom",
                 persist?: true
               )

      assert [row] = Repo.all(from e in ExperimentLedger, where: e.status == "failed")
      assert row.model_class == "boom"
      assert row.error =~ "boom"
    end
  end

  defp insert_row(metrics, sk, grade, status \\ "ok") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ExperimentLedger{}
    |> ExperimentLedger.changeset(%{
      source_key: sk,
      model_class: "linear_logreg",
      backtest_strategy: "temporal",
      granularity: "data_point",
      feature_bucket: "all",
      status: status,
      grade: grade,
      metrics: metrics,
      run_at: now
    })
    |> Repo.insert!()
  end
end
