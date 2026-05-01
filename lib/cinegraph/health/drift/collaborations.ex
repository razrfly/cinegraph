defmodule Cinegraph.Health.Drift.Collaborations do
  @moduledoc """
  Collaboration graph drift checks.
  """

  alias Cinegraph.Health.Drift
  alias Cinegraph.Maintenance.Collaborations, as: CollaborationMaintenance

  @cache_ttl :timer.minutes(5)
  @example_limit 10

  def all(opts \\ []) do
    Drift.run_all([
      fn -> missing_details(opts) end,
      fn -> queue_backlog(_opts = opts) end,
      fn -> recent_failures(opts) end
    ])
  end

  def missing_details(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:collaborations, :missing_details, limit}, @cache_ttl, fn ->
      stats = CollaborationMaintenance.stats()
      ids = CollaborationMaintenance.missing_movie_ids(limit: limit)

      examples =
        Enum.map(ids, fn id ->
          %{id: id, reason: "full movie has normalized credits but no collaboration_details"}
        end)

      Drift.result(
        :collaborations,
        :missing_details,
        stats.full_movies_with_credits,
        stats.missing_collaboration_details,
        examples
      )
    end)
  end

  def queue_backlog(_opts \\ []) do
    Drift.cached({:collaborations, :queue_backlog}, @cache_ttl, fn ->
      stats = CollaborationMaintenance.stats()
      q = stats.queue
      backlog = q.available + q.scheduled + q.retryable + q.executing

      examples = [
        %{
          queue: "collaboration",
          available: q.available,
          scheduled: q.scheduled,
          retryable: q.retryable,
          executing: q.executing,
          reason: "active or pending collaboration rebuild jobs"
        }
      ]

      Drift.result(:collaborations, :queue_backlog, max(backlog, 1), backlog, examples)
    end)
  end

  def recent_failures(_opts \\ []) do
    Drift.cached({:collaborations, :recent_failures}, @cache_ttl, fn ->
      stats = CollaborationMaintenance.stats()

      examples = [
        %{
          queue: "collaboration",
          recent_window_hours: stats.recent_window_hours,
          recent_failures: stats.recent_failures,
          reason: "discarded/retryable/cancelled CollaborationWorker jobs in recent window"
        }
      ]

      Drift.result(
        :collaborations,
        :recent_failures,
        max(stats.recent_completed_jobs + stats.recent_failures, 1),
        stats.recent_failures,
        examples
      )
    end)
  end
end
