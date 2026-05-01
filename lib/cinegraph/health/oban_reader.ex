defmodule Cinegraph.Health.ObanReader do
  @moduledoc """
  Centralized read access to `oban_jobs` for health surfaces.

  Single source of truth — used by `Cinegraph.Health.Queues` and
  `Cinegraph.Health.Activity`. No other module should query `oban_jobs`
  directly for health metrics.
  """

  import Ecto.Query
  alias Cinegraph.Repo

  @doc """
  Counts jobs grouped by `(queue, state)` for the given queues and states.

  Returns `%{queue_atom => %{state_string => count}}`.
  """
  def counts_by_queue_and_state(queues, states) do
    queue_strs = Enum.map(queues, &to_string/1)
    state_strs = Enum.map(states, &to_string/1)

    from(j in Oban.Job,
      where: j.queue in ^queue_strs and j.state in ^state_strs,
      group_by: [j.queue, j.state],
      select: {j.queue, j.state, count(j.id)}
    )
    |> Repo.replica().all()
    |> Enum.reduce(%{}, fn {queue, state, count}, acc ->
      # Use to_existing_atom so an unexpected queue string in the DB can't
      # silently grow the atom table. Configured queues become atoms at boot
      # via Application config, so any miss here is a real anomaly worth
      # surfacing.
      queue_atom =
        try do
          String.to_existing_atom(queue)
        rescue
          ArgumentError ->
            raise ArgumentError,
                  "oban_jobs row references queue #{inspect(queue)} that is not configured " <>
                    "for this app (no matching atom). Update :cinegraph, Oban[:queues] or " <>
                    "investigate the orphan job."
        end

      Map.update(acc, queue_atom, %{state => count}, &Map.put(&1, state, count))
    end)
  end

  @doc """
  Counts completed jobs since `since` (optionally for a specific queue).
  """
  def count_completed_since(%DateTime{} = since, queue \\ nil) do
    count_completed_in(since, nil, queue)
  end

  @doc """
  Counts completed jobs in a half-open interval `[start_dt, end_dt)`.
  Pass `nil` for `end_dt` to mean "until now".
  """
  def count_completed_in(%DateTime{} = start_dt, end_dt, queue \\ nil) do
    base =
      from(j in Oban.Job,
        where: j.state == "completed" and j.completed_at >= ^start_dt,
        select: count(j.id)
      )

    base = if end_dt, do: from(j in base, where: j.completed_at < ^end_dt), else: base
    base = if queue, do: from(j in base, where: j.queue == ^to_string(queue)), else: base
    Repo.replica().one(base) || 0
  end

  @doc """
  Counts failed jobs (`discarded` + `cancelled`) since `since` (optionally per queue).

  Oban stores the time differently per terminal state:

    * `discarded` → `discarded_at`
    * `cancelled` → `cancelled_at`
  """
  def count_failed_since(%DateTime{} = since, queue \\ nil) do
    count_failed_in(since, nil, queue)
  end

  @doc """
  Counts failed jobs in `[start_dt, end_dt)`. Pass `nil` for `end_dt` to mean "until now".
  """
  def count_failed_in(%DateTime{} = start_dt, end_dt, queue \\ nil) do
    discarded =
      from(j in Oban.Job,
        where: j.state == "discarded" and j.discarded_at >= ^start_dt,
        select: count(j.id)
      )

    cancelled =
      from(j in Oban.Job,
        where: j.state == "cancelled" and j.cancelled_at >= ^start_dt,
        select: count(j.id)
      )

    {discarded, cancelled} =
      if end_dt do
        {from(j in discarded, where: j.discarded_at < ^end_dt),
         from(j in cancelled, where: j.cancelled_at < ^end_dt)}
      else
        {discarded, cancelled}
      end

    {discarded, cancelled} =
      if queue do
        q = to_string(queue)
        {from(j in discarded, where: j.queue == ^q), from(j in cancelled, where: j.queue == ^q)}
      else
        {discarded, cancelled}
      end

    (Repo.replica().one(discarded) || 0) + (Repo.replica().one(cancelled) || 0)
  end

  @doc """
  Returns the longest currently-executing job's runtime in seconds for `queue`.
  Returns 0 if no jobs are executing.
  """
  def longest_running_seconds(queue) do
    queue_str = to_string(queue)

    # `attempted_at` is :utc_datetime_usec which Ecto stores as `timestamp WITHOUT
    # TIME ZONE` holding UTC wall-clock. `NOW()` is timestamptz; comparing
    # to `attempted_at` would silently shift by the session timezone offset,
    # producing wrong elapsed seconds. Use `NOW() AT TIME ZONE 'UTC'` to
    # subtract apples-to-apples.
    from(j in Oban.Job,
      where: j.queue == ^queue_str and j.state == "executing",
      select:
        fragment(
          "EXTRACT(EPOCH FROM ((NOW() AT TIME ZONE 'UTC') - ?))::integer",
          j.attempted_at
        ),
      order_by: [asc: j.attempted_at],
      limit: 1
    )
    |> Repo.replica().one()
    |> case do
      nil -> 0
      seconds -> seconds
    end
  end

  @doc """
  Per-`source_key` job summary for `worker` over the window
  `[start_dt, end_dt)`. Pass `nil` for `end_dt` to mean "until now".
  Used by worker-level audits (e.g. `Cinegraph.Health.YearDiscovery`).

  Returns `%{source_key_string => %{
    discarded: integer, completed: integer, retryable: integer,
    last_error: String.t | nil,
    last_failure_at: DateTime.t | nil,
    attempts_used: integer
  }}`.

  Festivals with zero jobs in the window do not appear here — the caller
  joins with the active-festivals list and fills in the gaps.
  """
  def jobs_summary_for_worker(worker, %DateTime{} = start_dt, end_dt \\ nil)
      when is_binary(worker) do
    # Retryable jobs are filtered by `attempted_at` (when last attempted)
    # so they respect the same window as discarded/completed. A retryable
    # job that hasn't been touched in months is a stuck-job anomaly and
    # belongs to a separate signal, not a "last N days" audit.
    rows =
      from(j in Oban.Job,
        where: j.worker == ^worker,
        where:
          (j.state == "discarded" and j.discarded_at >= ^start_dt) or
            (j.state == "completed" and j.completed_at >= ^start_dt) or
            (j.state == "retryable" and j.attempted_at >= ^start_dt),
        select: %{
          state: j.state,
          source_key: fragment("?->>'source_key'", j.args),
          attempt: j.attempt,
          discarded_at: j.discarded_at,
          completed_at: j.completed_at,
          attempted_at: j.attempted_at,
          # `errors` is a jsonb[]; index the last element and pull its `error` key.
          # Empty arrays / non-failures yield nil.
          last_error:
            fragment(
              "CASE WHEN array_length(?, 1) > 0 THEN ?[array_upper(?, 1)] ->> 'error' ELSE NULL END",
              j.errors,
              j.errors,
              j.errors
            )
        }
      )
      |> Repo.replica().all()

    rows =
      if end_dt do
        Enum.filter(rows, fn r ->
          case r.state do
            "discarded" -> DateTime.compare(r.discarded_at, end_dt) == :lt
            "completed" -> DateTime.compare(r.completed_at, end_dt) == :lt
            "retryable" -> DateTime.compare(r.attempted_at, end_dt) == :lt
            _ -> true
          end
        end)
      else
        rows
      end

    rows
    |> Enum.group_by(& &1.source_key)
    |> Map.new(fn {source_key, group} ->
      discarded = Enum.filter(group, &(&1.state == "discarded"))
      completed_count = Enum.count(group, &(&1.state == "completed"))
      retryable_count = Enum.count(group, &(&1.state == "retryable"))

      latest_failure =
        discarded
        |> Enum.sort_by(& &1.discarded_at, {:desc, DateTime})
        |> List.first()

      summary = %{
        discarded: length(discarded),
        completed: completed_count,
        retryable: retryable_count,
        last_error: latest_failure && latest_failure.last_error,
        last_failure_at: latest_failure && latest_failure.discarded_at,
        attempts_used: (latest_failure && latest_failure.attempt) || 0
      }

      {source_key, summary}
    end)
  end

  @doc """
  Discarded jobs in `[start_dt, end_dt)` for a queue and/or worker filter.
  Returns rows with worker, attempt, discarded_at, and the most recent
  `errors[].error` text. The caller groups by error pattern.

  At least one of `:queue` or `:worker` must be provided.
  """
  def discards_for_queue(opts, %DateTime{} = start_dt, end_dt \\ nil) do
    queue = Keyword.get(opts, :queue)
    worker = Keyword.get(opts, :worker)

    if is_nil(queue) and is_nil(worker) do
      raise ArgumentError, "discards_for_queue/3 requires :queue or :worker"
    end

    base =
      from(j in Oban.Job,
        where: j.state == "discarded" and j.discarded_at >= ^start_dt,
        order_by: [asc: j.discarded_at, asc: j.id],
        select: %{
          id: j.id,
          worker: j.worker,
          attempt: j.attempt,
          discarded_at: j.discarded_at,
          last_error:
            fragment(
              "CASE WHEN array_length(?, 1) > 0 THEN ?[array_upper(?, 1)] ->> 'error' ELSE NULL END",
              j.errors,
              j.errors,
              j.errors
            )
        }
      )

    base = if queue, do: from(j in base, where: j.queue == ^to_string(queue)), else: base
    base = if worker, do: from(j in base, where: j.worker == ^worker), else: base

    base = if end_dt, do: from(j in base, where: j.discarded_at < ^end_dt), else: base

    Repo.replica().all(base)
  end

  @doc """
  Returns the list of queue names configured for Oban (atoms).
  """
  def configured_queues do
    case Application.get_env(:cinegraph, :known_oban_queues) do
      queues when is_list(queues) and queues != [] ->
        queues

      _ ->
        configured_queues_from_oban()
    end
  end

  defp configured_queues_from_oban do
    case Application.get_env(:cinegraph, Oban) do
      nil ->
        []

      config ->
        config
        |> Keyword.get(:queues, [])
        |> Enum.map(fn {q, _concurrency} -> q end)
    end
  end
end
