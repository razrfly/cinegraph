defmodule Cinegraph.Workers.RatingsRefreshWorker do
  @moduledoc """
  Daily cron orchestrator for OMDb data enrichment.

  Runs at 3 AM UTC and drains the OMDb null backlog in two phases:

  ## Phase A – Gap Fill
  Queries movies with `omdb_data IS NULL` ordered by TMDb popularity DESC
  and queues them via `OMDbEnrichmentWorker`.

  ## Phase B – Stale Refresh
  If Phase A fills fewer than `batch_size` slots, tops up with the
  stalest-fetched movies (by `external_metrics.fetched_at` for source='omdb'),
  queuing with `"force" => true` to bypass the existing-data skip.

  ## Configuration
  - `OMDB_DAILY_BATCH_SIZE` env var (default 500)
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 23 * 3600,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Movies.ExternalMetric
  alias Cinegraph.Workers.OMDbEnrichmentWorker
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    batch_size = Application.get_env(:cinegraph, :omdb_daily_batch_size, 500)
    Logger.info("RatingsRefresh: Starting daily OMDb refresh (batch_size=#{batch_size})")

    phase_a_count = run_phase_a(batch_size)
    Logger.info("RatingsRefresh: Phase A queued #{phase_a_count} null-backlog movies")

    remaining = batch_size - phase_a_count

    if remaining > 0 do
      phase_b_count = run_phase_b(remaining)
      Logger.info("RatingsRefresh: Phase B queued #{phase_b_count} stale-refresh movies")
    else
      Logger.info("RatingsRefresh: Phase A filled batch, skipping Phase B")
    end

    :ok
  end

  # Phase A: queue movies where omdb_data IS NULL, by popularity DESC
  defp run_phase_a(limit) do
    movie_ids =
      from(m in Movie,
        where: is_nil(m.omdb_data),
        order_by: [desc_nulls_last: m.popularity],
        limit: ^limit,
        select: m.id
      )
      |> Repo.all()

    queue_enrichment_jobs(movie_ids, %{})
  end

  # Phase B: queue movies with omdb_data, stalest external_metrics.fetched_at first
  defp run_phase_b(limit) do
    stalest_subquery =
      from(em in ExternalMetric,
        where: em.source == "omdb",
        group_by: em.movie_id,
        select: %{movie_id: em.movie_id, last_fetched: max(em.fetched_at)}
      )

    movie_ids =
      from(m in Movie,
        where: not is_nil(m.omdb_data),
        left_join: s in subquery(stalest_subquery),
        on: s.movie_id == m.id,
        order_by: [asc_nulls_first: s.last_fetched],
        limit: ^limit,
        select: m.id
      )
      |> Repo.all()

    queue_enrichment_jobs(movie_ids, %{"force" => true})
  end

  defp queue_enrichment_jobs([], _extra_args), do: 0

  defp queue_enrichment_jobs(movie_ids, extra_args) do
    jobs =
      Enum.map(movie_ids, fn id ->
        OMDbEnrichmentWorker.new(Map.merge(%{"movie_id" => id}, extra_args))
      end)

    case Oban.insert_all(jobs) do
      inserted when is_list(inserted) -> length(inserted)
      _ -> 0
    end
  end
end
