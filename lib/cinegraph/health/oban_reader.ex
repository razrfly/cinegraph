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
  Returns the list of queue names configured for Oban (atoms).
  """
  def configured_queues do
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
