defmodule Cinegraph.Predictions.RunReporter do
  @moduledoc """
  Writes the `prediction_runs` lifecycle row (#1065 Session 2) — start, live per-cell progress, finish.

  Plain functions (no process): a run calls these from its own process, so DB writes inherit the
  caller's Ecto sandbox in tests. `record/2` is the live heartbeat — one atomic UPDATE that bumps a
  counter and refreshes `updated_at` (so the dashboard reads progress straight from the row and can
  detect a dead run by a stale heartbeat), then a lightweight PubSub nudge for same-node listeners.
  PubSub is acceleration only; the DB row is the source of truth.
  """
  import Ecto.Query

  alias Cinegraph.Predictions.Run
  alias Cinegraph.Repo

  @topic "predictions:runs"

  @doc "The PubSub topic dashboards subscribe to for live nudges."
  def topic, do: @topic

  @doc """
  Open a run: insert the `prediction_runs` row in `running` state. Best-effort — a failed insert
  (e.g. a duplicate run_id) is logged and the run still proceeds; observability never blocks a run.
  """
  def start(run_id, kind, total, params) do
    %Run{}
    |> Run.changeset(%{
      run_id: run_id,
      kind: to_string(kind),
      status: "running",
      total_cells: total,
      params: stringify(params),
      node: to_string(node()),
      code_version: code_version(),
      started_at: utc_now()
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> warn("start", run_id, cs.errors)
    end
  end

  @doc """
  Record one finished cell: atomically `+1` to `completed_cells` (status `:ok`) or `failed_cells`
  (anything else), set `current_cell`, and touch `updated_at` (the heartbeat). Then nudge PubSub.
  No-op when `run_id` is nil (a standalone `run_cells`/`evaluate_cell` call with no run header).
  """
  def record(nil, _event), do: :ok

  def record(run_id, %{status: status} = event) do
    inc = if status == :ok, do: [completed_cells: 1], else: [failed_cells: 1]
    current = event[:current_cell]

    from(r in Run, where: r.run_id == ^run_id)
    |> Repo.update_all(inc: inc, set: [current_cell: current, updated_at: naive_now()])

    broadcast(run_id)
    :ok
  end

  @doc "Close a run: set `status`/`finished_at` (+ `error` on failure). No-op for a nil run_id."
  def finish(run_id, status, error \\ nil)

  def finish(nil, _status, _error), do: :ok

  def finish(run_id, status, error) do
    from(r in Run, where: r.run_id == ^run_id)
    |> Repo.update_all(
      set: [
        status: to_string(status),
        error: error && inspect_short(error),
        finished_at: naive_now(),
        updated_at: naive_now()
      ]
    )

    broadcast(run_id)
    :ok
  end

  # ── internals ───────────────────────────────────────────────────────────────────

  defp broadcast(run_id) do
    Phoenix.PubSub.broadcast(Cinegraph.PubSub, @topic, {:run_progress, run_id})
  rescue
    # PubSub may be absent in a headless task node; observability must never crash a run.
    _ -> :ok
  end

  # `params` may carry atoms (e.g. buckets) — JSON/jsonb wants string-safe values for storage.
  defp stringify(params) when is_list(params), do: params |> Map.new() |> stringify()

  defp stringify(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify(_), do: %{}

  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)

  defp stringify_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v),
    do: to_string(v)

  defp stringify_value(v), do: v

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp naive_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp inspect_short(error), do: error |> inspect() |> String.slice(0, 500)

  # App version + optional BUILD_SHA (no git, per repo policy) — mirrors Trainer.code_version/0.
  defp code_version do
    vsn =
      case Application.spec(:cinegraph, :vsn) do
        v when is_list(v) -> List.to_string(v)
        _ -> nil
      end

    case {vsn, System.get_env("BUILD_SHA")} do
      {v, sha} when is_binary(v) and is_binary(sha) -> "#{v}+#{sha}"
      {v, _} when is_binary(v) -> v
      {_, sha} when is_binary(sha) -> sha
      _ -> "unknown"
    end
  end

  defp warn(op, run_id, detail) do
    require Logger
    Logger.warning("RunReporter(#{op}): run #{run_id} not recorded: #{inspect(detail)}")
    :ok
  end
end
