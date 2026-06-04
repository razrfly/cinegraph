defmodule Cinegraph.Predictions.Runs do
  @moduledoc """
  Read model for the `/admin/predictions/runs` dashboard (#1065 Session 2, Phase 4).

  Progress/counters come straight from the `prediction_runs` lifecycle row (the live source of truth,
  updated per cell by `RunReporter`); the experiment ledger is joined only for the per-cell grid and
  the timing report. Heavy reads go through `Repo.replica/0`; the timing report is cached in
  `:predictions_cache`. The dashboard polls these every ~2.5s.
  """
  import Ecto.Query

  alias Cinegraph.Predictions.{ExperimentLedger, MatrixPlanner, Run}
  alias Cinegraph.Repo

  @stale_after_seconds 600
  @cache :predictions_cache
  @timing_ttl :timer.minutes(2)
  @valid_buckets ~w(objective_only canon_overlap all raw derived)

  @doc "Currently-running runs (most recent first), each flagged `stale` if its heartbeat is old."
  def active do
    Repo.replica().all(
      from r in Run, where: r.status == "running", order_by: [desc: r.started_at]
    )
    |> Enum.map(&summarize/1)
  end

  @doc "Recent runs of any kind/status, newest first, with derived wall-clock + throughput."
  def list_recent(limit \\ 20) do
    Repo.replica().all(from r in Run, order_by: [desc: r.inserted_at], limit: ^limit)
    |> Enum.map(&summarize/1)
  end

  @doc "One run's summary (or `nil`)."
  def get(run_id) do
    case Repo.replica().get_by(Run, run_id: run_id) do
      nil -> nil
      run -> summarize(run)
    end
  end

  @doc """
  A matrix run's cell grid: `%{columns: [{strategy, bucket}], rows: [%{source_key, cells}]}` where
  each cell status is `:ok | :failed | :running | :pending | :none`. `nil` for non-matrix runs.
  """
  def cell_grid(run_id) do
    case Repo.replica().get_by(Run, run_id: run_id) do
      %Run{kind: "matrix"} = run -> build_grid(run)
      _ -> nil
    end
  end

  @doc """
  Global timing report (cached): avg `duration_ms` by `(strategy, bucket)`, the fitted cost model
  (`k`/`r²`), and the slowest recorded cells.
  """
  def timing_report do
    case Cachex.fetch(@cache, :timing_report, fn ->
           {:commit, compute_timing(), ttl: @timing_ttl}
         end) do
      {:ok, report} -> report
      {:commit, report} -> report
      _ -> compute_timing()
    end
  end

  # ── summary ───────────────────────────────────────────────────────────────────────

  defp summarize(run) do
    ok = run.completed_cells || 0
    failed = run.failed_cells || 0
    done = ok + failed
    wall = wall_ms(run)

    %{
      run: run,
      done: done,
      total: run.total_cells,
      ok: ok,
      failed: failed,
      pct: pct(done, run.total_cells),
      stale: stale?(run),
      wall_ms: wall,
      avg_cell_ms: if(done > 0 and wall, do: round(wall / done), else: nil),
      throughput_per_min: throughput(done, wall),
      eta_ms: eta_ms(run)
    }
  end

  defp wall_ms(%{started_at: nil}), do: nil

  defp wall_ms(run) do
    DateTime.diff(run.finished_at || DateTime.utc_now(), run.started_at, :millisecond)
  end

  defp throughput(done, wall) when is_integer(wall) and wall > 0 and done > 0,
    do: Float.round(done / (wall / 60_000), 1)

  defp throughput(_done, _wall), do: nil

  defp pct(_done, total) when total in [nil, 0], do: 0
  defp pct(done, total), do: round(done / total * 100)

  defp stale?(%{status: "running", updated_at: u}) when not is_nil(u),
    do: NaiveDateTime.diff(NaiveDateTime.utc_now(), u) > @stale_after_seconds

  defp stale?(_), do: false

  # ── ETA (running matrix runs: price the cells not yet in the ledger) ───────────────

  defp eta_ms(%Run{status: "running", kind: "matrix"} = run) do
    case plan_opts(run.params) do
      nil ->
        nil

      opts ->
        done = done_keys(run.run_id)
        conc = max(int(run.params["max_concurrency"]) || 4, 1)

        opts
        |> MatrixPlanner.plan()
        |> Map.fetch!(:cells)
        |> MatrixPlanner.price_cells()
        |> Enum.reject(&MapSet.member?(done, cell_key(&1)))
        |> Enum.map(& &1.predicted_ms)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> 0
          ms -> ceil(Enum.sum(ms) / conc)
        end
    end
  rescue
    # A params shape the planner can't reconstruct (e.g. a retired class) shouldn't break the row.
    _ -> nil
  end

  defp eta_ms(_), do: nil

  # ── cell grid ─────────────────────────────────────────────────────────────────────

  defp build_grid(run) do
    seen =
      Repo.replica().all(
        from e in ExperimentLedger,
          where: e.run_id == ^run.run_id,
          select: {e.source_key, e.backtest_strategy, e.feature_bucket, e.status}
      )
      |> Map.new(fn {sk, s, b, status} -> {{sk, s, b}, status_atom(status)} end)

    planned =
      case plan_opts(run.params) do
        nil -> []
        opts -> MatrixPlanner.plan(opts).cells |> Enum.map(&cell_key/1)
      end

    keys = Enum.uniq(planned ++ Map.keys(seen))
    key_set = MapSet.new(keys)
    columns = keys |> Enum.map(fn {_sk, s, b} -> {s, b} end) |> Enum.uniq() |> Enum.sort()
    sources = keys |> Enum.map(fn {sk, _, _} -> sk end) |> Enum.uniq() |> Enum.sort()

    rows =
      Enum.map(sources, fn sk ->
        cells =
          Map.new(columns, fn {s, b} ->
            {{s, b}, cell_status({sk, s, b}, seen, key_set, run.current_cell)}
          end)

        %{source_key: sk, cells: cells}
      end)

    %{columns: columns, rows: rows}
  end

  defp cell_status(key, seen, key_set, current_cell) do
    {sk, s, b} = key

    cond do
      Map.has_key?(seen, key) -> Map.fetch!(seen, key)
      current_cell == "#{sk}/#{s}/#{b}" -> :running
      MapSet.member?(key_set, key) -> :pending
      true -> :none
    end
  end

  defp status_atom("ok"), do: :ok
  defp status_atom("failed"), do: :failed
  defp status_atom(_), do: :pending

  # ── timing report ─────────────────────────────────────────────────────────────────

  defp compute_timing do
    by_shape =
      Repo.replica().all(
        from e in ExperimentLedger,
          where: not is_nil(e.duration_ms),
          group_by: [e.backtest_strategy, e.feature_bucket],
          order_by: [e.backtest_strategy, e.feature_bucket],
          select: %{
            strategy: e.backtest_strategy,
            bucket: e.feature_bucket,
            avg_ms: avg(e.duration_ms),
            n: count(e.id)
          }
      )

    slowest =
      Repo.replica().all(
        from e in ExperimentLedger,
          where: not is_nil(e.duration_ms),
          order_by: [desc: e.duration_ms],
          limit: 8,
          select: %{
            source_key: e.source_key,
            strategy: e.backtest_strategy,
            bucket: e.feature_bucket,
            duration_ms: e.duration_ms,
            n_evaluated: e.n_evaluated
          }
      )

    %{by_shape: by_shape, slowest: slowest, cost_model: MatrixPlanner.cost_model()}
  end

  # ── helpers ───────────────────────────────────────────────────────────────────────

  defp done_keys(run_id) do
    Repo.replica().all(
      from e in ExperimentLedger,
        where: e.run_id == ^run_id,
        distinct: true,
        select: {e.source_key, e.backtest_strategy, e.feature_bucket}
    )
    |> MapSet.new()
  end

  defp cell_key(%{source_key: sk, strategy: s, feature_bucket: b}),
    do: {sk, s, to_string(b)}

  # Rebuild MatrixPlanner opts from the stored (string-keyed, string-bucket) params.
  defp plan_opts(params) when is_map(params) do
    opts =
      [
        lists: params["lists"],
        classes: params["classes"],
        strategies: params["strategies"],
        buckets: params["buckets"] && Enum.map(params["buckets"], &bucket_atom/1),
        max_concurrency: params["max_concurrency"]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    if Keyword.has_key?(opts, :lists), do: opts, else: nil
  end

  defp plan_opts(_), do: nil

  defp bucket_atom(b) when b in @valid_buckets, do: String.to_atom(b)
  defp bucket_atom(_), do: :all

  defp int(n) when is_integer(n), do: n
  defp int(_), do: nil
end
