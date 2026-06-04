defmodule Cinegraph.Predictions.RunsTest do
  @moduledoc """
  The run *lifecycle* (#1065 Session 2): `run_matrix` opens/advances/closes a `prediction_runs` row,
  promote stamps `run_id` on its model, and the `Runs` read model surfaces active/recent/grid/timing.
  """
  use Cinegraph.DataCase

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.{Model, PreRegistration, Run, Runs, Trainer}
  alias Cinegraph.Repo

  @list "runs_test_list"

  setup do
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

    for {decade, members, others} <- [{1980, 8, 20}, {1990, 8, 20}, {2000, 10, 24}] do
      for i <- 1..members, do: plant(decade, i, true)
      for i <- 1..others, do: plant(decade, 100 + i, false)
    end

    :ok
  end

  describe "run_matrix lifecycle (prediction_runs)" do
    test "opens a running row, advances live counters, and closes it completed" do
      rows =
        Trainer.run_matrix(
          lists: [@list],
          classes: ["linear_logreg"],
          strategies: ["temporal"],
          buckets: [:objective_only, :all],
          max_concurrency: 2
        )

      assert length(rows) == 2
      assert [run] = Repo.all(Run)
      assert run.kind == "matrix"
      assert run.status == "completed"
      assert run.total_cells == 2
      assert run.completed_cells == 2
      assert run.failed_cells == 0
      assert run.current_cell =~ @list
      assert run.started_at && run.finished_at
      # params are stored string-keyed for reproducibility (and ETA reconstruction).
      assert run.params["lists"] == [@list]
      assert run.params["buckets"] == ["objective_only", "all"]
    end

    test "the on_cell callback fires once per cell (matrix + pooled)" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Trainer.run_matrix(
        lists: [@list],
        classes: ["linear_logreg"],
        strategies: ["temporal"],
        buckets: [:objective_only, :all],
        max_concurrency: 2,
        on_progress: fn _event -> Agent.update(counter, &(&1 + 1)) end
      )

      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "Runs read model" do
    setup do
      Trainer.run_matrix(
        lists: [@list],
        classes: ["linear_logreg"],
        strategies: ["temporal"],
        buckets: [:objective_only, :all],
        max_concurrency: 2
      )

      :ok
    end

    test "list_recent summarizes the run with derived wall-clock + avg/cell" do
      assert [summary] = Runs.list_recent(10)
      assert summary.total == 2
      assert summary.done == 2
      assert summary.pct == 100
      assert is_integer(summary.wall_ms)
      assert is_integer(summary.avg_cell_ms)
      refute summary.stale
    end

    test "active/0 is empty once the run completed" do
      assert Runs.active() == []
    end

    test "cell_grid shapes ledger rows into lists × {strategy/bucket} with statuses" do
      [run] = Repo.all(Run)
      grid = Runs.cell_grid(run.run_id)

      assert {"temporal", "all"} in grid.columns
      assert {"temporal", "objective_only"} in grid.columns
      assert [%{source_key: @list, cells: cells}] = grid.rows
      assert cells[{"temporal", "all"}] == :ok
      assert cells[{"temporal", "objective_only"}] == :ok
    end

    test "timing_report exposes avg-by-shape and (with variance) a fitted cost model" do
      report = Runs.timing_report()
      assert is_list(report.by_shape)
      assert length(report.by_shape) >= 1
      assert Map.has_key?(report, :cost_model)
      assert Map.has_key?(report, :slowest)
    end
  end

  test "active/0 flags a running row with a stale heartbeat" do
    stale =
      NaiveDateTime.add(NaiveDateTime.utc_now(), -3600, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.insert!(%Run{
      run_id: "matrix-stale",
      kind: "matrix",
      status: "running",
      total_cells: 10,
      completed_cells: 2,
      failed_cells: 0,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      inserted_at: stale,
      updated_at: stale
    })

    assert [active] = Runs.active()
    assert active.stale
    assert active.done == 2
  end

  test "promote (Trainer.train save) stamps run_id on the model row" do
    {:ok, prereg} =
      PreRegistration.register(%{
        source_key: @list,
        expected_top_features: %{},
        expected_accuracy_range: %{"min" => 0.0, "max" => 1.0},
        failure_threshold: "0.0000"
      })

    assert {:ok, _summary} =
             Trainer.train(@list,
               granularity: :data_point,
               save: true,
               backtest_strategy: "temporal",
               prereg: prereg,
               run_id: "promote-xyz"
             )

    assert [model] = Repo.all(Model)
    assert model.run_id == "promote-xyz"
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
