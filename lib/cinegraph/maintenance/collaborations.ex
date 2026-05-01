defmodule Cinegraph.Maintenance.Collaborations do
  @moduledoc """
  Maintenance entry point for collaboration graph coverage.

  This module only enqueues the existing idempotent `CollaborationWorker`;
  actual graph writes stay centralized in `Cinegraph.Collaborations`.
  """

  alias Cinegraph.Repo
  alias Cinegraph.Workers.CollaborationWorker

  require Logger

  @default_limit 5_000
  @insert_chunk_size 500
  @recent_window_hours 24

  def stats do
    full_with_credits = scalar(full_with_credits_sql())
    covered = scalar(covered_sql())
    missing = max(full_with_credits - covered, 0)

    %{
      generated_at: DateTime.utc_now(),
      full_movies_with_credits: full_with_credits,
      movies_with_collaboration_details: covered,
      missing_collaboration_details: missing,
      coverage_pct: coverage_pct(covered, full_with_credits),
      queue: queue_counts(),
      recent_completed_jobs: recent_completed_jobs(),
      recent_failures: recent_failures(),
      recent_window_hours: @recent_window_hours
    }
  end

  def missing_movie_ids(opts \\ []) do
    limit = positive_limit!(Keyword.get(opts, :limit, @default_limit))

    """
    SELECT m.id
    FROM movies m
    WHERE m.import_status = 'full'
      AND #{eligible_credits_exists_sql()}
      AND NOT EXISTS (SELECT 1 FROM collaboration_details cd WHERE cd.movie_id = m.id)
    ORDER BY m.id
    LIMIT $1
    """
    |> query_rows([limit])
    |> Enum.map(fn [id] -> id end)
  end

  def backfill(opts \\ []) do
    limit = positive_limit!(Keyword.get(opts, :limit, @default_limit))
    dry_run? = Keyword.get(opts, :dry_run, false)
    ids = missing_movie_ids(limit: limit)

    result =
      if dry_run? do
        %{found: length(ids), enqueued: 0, failed: 0, dry_run: true, movie_ids: ids}
      else
        {enqueued, failed} = enqueue_in_chunks(ids)
        %{found: length(ids), enqueued: enqueued, failed: failed, dry_run: false, movie_ids: ids}
      end

    {:ok, Map.merge(result, %{stats: stats()})}
  end

  def repair_movie(movie_id) when is_integer(movie_id) do
    before_details = detail_count(movie_id)
    has_credits? = has_credits?(movie_id)

    case enqueue_one(movie_id) do
      :ok ->
        {:ok,
         %{
           movie_id: movie_id,
           has_credits: has_credits?,
           detail_count_before: before_details,
           enqueued: 1,
           failed: 0
         }}

      {:error, reason} ->
        {:ok,
         %{
           movie_id: movie_id,
           has_credits: has_credits?,
           detail_count_before: before_details,
           enqueued: 0,
           failed: 1,
           error: inspect(reason)
         }}
    end
  end

  def repair_movie(movie_id) when is_binary(movie_id) do
    case Integer.parse(movie_id) do
      {id, ""} -> repair_movie(id)
      _ -> raise ArgumentError, "movie_id must be an integer, got: #{inspect(movie_id)}"
    end
  end

  defp enqueue_in_chunks(movie_ids) do
    movie_ids
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      jobs = Enum.map(chunk, &CollaborationWorker.new(%{"movie_id" => &1}))

      try do
        case Oban.insert_all(jobs) do
          results when is_list(results) ->
            {ok + length(results), err}

          other ->
            Logger.error("Collaboration backfill insert_all returned #{inspect(other)}")
            {ok, err + length(chunk)}
        end
      rescue
        e ->
          Logger.error("Collaboration backfill insert_all failed: #{Exception.message(e)}")
          {ok, err + length(chunk)}
      end
    end)
  end

  defp enqueue_one(movie_id) do
    %{"movie_id" => movie_id}
    |> CollaborationWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp full_with_credits_sql do
    """
    SELECT count(*)::bigint
    FROM movies m
    WHERE m.import_status = 'full'
      AND #{eligible_credits_exists_sql()}
    """
  end

  defp covered_sql do
    """
    SELECT count(DISTINCT m.id)::bigint
    FROM movies m
    WHERE m.import_status = 'full'
      AND #{eligible_credits_exists_sql()}
      AND EXISTS (SELECT 1 FROM collaboration_details cd WHERE cd.movie_id = m.id)
    """
  end

  defp eligible_credits_exists_sql do
    """
    EXISTS (
      SELECT 1
      FROM movie_credits mc
      WHERE mc.movie_id = m.id
      GROUP BY mc.movie_id
      HAVING count(DISTINCT mc.person_id) >= 2
    )
    """
  end

  defp queue_counts do
    rows =
      """
      SELECT state, count(*)::bigint
      FROM oban_jobs
      WHERE queue = 'collaboration'
      GROUP BY state
      """
      |> query_rows([])

    base = %{
      available: 0,
      executing: 0,
      scheduled: 0,
      retryable: 0,
      completed: 0,
      discarded: 0,
      cancelled: 0
    }

    Enum.reduce(rows, base, fn [state, count], acc ->
      Map.put(acc, String.to_atom(state), count)
    end)
  end

  defp recent_completed_jobs do
    scalar(
      """
      SELECT count(*)::bigint
      FROM oban_jobs
      WHERE queue = 'collaboration'
        AND worker = 'Cinegraph.Workers.CollaborationWorker'
        AND state = 'completed'
        AND completed_at > (now() - ($1::int * interval '1 hour'))
      """,
      [@recent_window_hours]
    )
  end

  defp recent_failures do
    scalar(
      """
      SELECT count(*)::bigint
      FROM oban_jobs
      WHERE queue = 'collaboration'
        AND worker = 'Cinegraph.Workers.CollaborationWorker'
        AND state IN ('discarded', 'retryable', 'cancelled')
        AND attempted_at > (now() - ($1::int * interval '1 hour'))
      """,
      [@recent_window_hours]
    )
  end

  defp detail_count(movie_id) do
    scalar("SELECT count(*)::bigint FROM collaboration_details WHERE movie_id = $1", [movie_id])
  end

  defp has_credits?(movie_id) do
    scalar("SELECT count(*)::bigint FROM movie_credits WHERE movie_id = $1", [movie_id]) > 0
  end

  defp scalar(sql, params \\ []) do
    case Ecto.Adapters.SQL.query!(Repo.replica(), sql, params) do
      %{rows: [[value]]} -> value || 0
      _ -> 0
    end
  end

  defp query_rows(sql, params) do
    case Ecto.Adapters.SQL.query!(Repo.replica(), sql, params) do
      %{rows: rows} -> rows
      _ -> []
    end
  end

  defp coverage_pct(_covered, 0), do: 100.0
  defp coverage_pct(covered, total), do: Float.round(covered / total * 100, 2)

  defp positive_limit!(value) when is_integer(value) and value > 0, do: value

  defp positive_limit!(value),
    do: raise(ArgumentError, "limit must be a positive integer, got: #{inspect(value)}")
end
