defmodule Cinegraph.Health.Facade do
  @moduledoc """
  Orchestrates the I/O that `Verdict` (pure) cannot do.

  Used by `mix cinegraph.health` and `mix cinegraph.status`. Also the
  read path for `/admin/health` (#723).
  """

  alias Cinegraph.Health.{Activity, Queues, Verdict}

  @cache_name :health_cache

  @doc """
  Run all 4 drift domains in parallel, roll them up via `Verdict.compute/1`.

  ## Options

    * `:bypass_cache` — when `true`, clears `:health_cache` before computing
      so every drift check runs fresh. Used by the LiveView's "Refresh now"
      button and by mix tasks.
  """
  def compute_full_verdict(opts \\ []) do
    if Keyword.get(opts, :bypass_cache, false) do
      Cachex.clear(@cache_name)
    end

    domain_results =
      [
        people: Cinegraph.Health.Drift.People,
        movies: Cinegraph.Health.Drift.Movies,
        festivals: Cinegraph.Health.Drift.Festivals,
        ratings: Cinegraph.Health.Drift.Ratings
      ]
      |> Enum.map(fn {domain, mod} ->
        Task.async(fn -> {domain, mod.all()} end)
      end)
      |> Task.await_many(120_000)
      |> Enum.into(%{})

    Verdict.compute(domain_results)
  end

  @doc """
  Snapshot for `mix cinegraph.status` — activity + queues + last sync timestamp.
  """
  def compute_status do
    %{
      generated_at: DateTime.utc_now(),
      activity_today: Activity.today(bypass_cache: true),
      queues: Queues.snapshot(bypass_cache: true),
      last_sync_at: last_sync_timestamp()
    }
  end

  defp last_sync_timestamp do
    sql = "SELECT MAX(updated_at) FROM movies"

    case Ecto.Adapters.SQL.query!(Cinegraph.Repo.replica(), sql, []) do
      %{rows: [[ts]]} -> ts
      _ -> nil
    end
  end
end
