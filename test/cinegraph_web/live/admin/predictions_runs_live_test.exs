defmodule CinegraphWeb.Admin.PredictionsRunsLiveTest do
  @moduledoc "The /admin/predictions/runs dashboard (#1065 Phase 4) renders active + history + timing."
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Predictions.{ExperimentLedger, Run}
  alias Cinegraph.Repo

  setup do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # A completed matrix run with two ledger cells (one ok, one failed) + a running run.
    Repo.insert!(%Run{
      run_id: "matrix-done",
      kind: "matrix",
      status: "completed",
      total_cells: 2,
      completed_cells: 1,
      failed_cells: 1,
      current_cell: "afi_100/temporal/all",
      params: %{
        "lists" => ["afi_100"],
        "classes" => ["linear_logreg"],
        "strategies" => ["temporal"],
        "buckets" => ["objective_only", "all"]
      },
      started_at: now,
      finished_at: now
    })

    Repo.insert!(%Run{
      run_id: "matrix-running",
      kind: "matrix",
      status: "running",
      total_cells: 4,
      completed_cells: 1,
      failed_cells: 0,
      current_cell: "afi_100/static/all",
      params: %{"lists" => ["afi_100"]},
      started_at: now
    })

    for {bucket, status} <- [{"objective_only", "ok"}, {"all", "failed"}] do
      Repo.insert!(%ExperimentLedger{
        source_key: "afi_100",
        model_class: "linear_logreg",
        backtest_strategy: "temporal",
        feature_bucket: bucket,
        granularity: "data_point",
        status: status,
        run_id: "matrix-done",
        duration_ms: 5000,
        n_evaluated: 4000,
        run_at: now
      })
    end

    :ok
  end

  test "renders active run, recent history, cell grid, and timing report", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/admin/predictions/runs")

    assert html =~ "Prediction Runs"
    # active run card
    assert html =~ "matrix-running"
    assert html =~ "1/4 cells"
    # recent history
    assert html =~ "Recent runs"
    assert html =~ "matrix-done"
    assert html =~ "completed"
    # cell grid (the selected run's ledger cells)
    assert html =~ "Cell grid"
    assert html =~ "temporal/all"
    # timing report
    assert html =~ "Timing report"
    assert html =~ "Slowest cells"
  end

  test "clicking a recent run selects it and shows its grid", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/admin/predictions/runs")

    html = live |> element("tr[phx-value-id='matrix-done']") |> render_click()

    assert html =~ "afi_100"
  end
end
