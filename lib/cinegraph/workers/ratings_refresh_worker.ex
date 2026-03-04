defmodule Cinegraph.Workers.RatingsRefreshWorker do
  @moduledoc """
  Daily cron orchestrator for OMDb data enrichment.

  Runs at 3 AM UTC and drains the OMDb null backlog in two phases:

  ## Phase A – Gap Fill
  Queries movies with `omdb_data IS NULL` (and `import_status = 'full'`,
  `imdb_id IS NOT NULL`) ordered by TMDb popularity DESC and queues them
  via `OMDbEnrichmentWorker`.

  ## Phase B – Stale Refresh
  If Phase A fills fewer than `batch_size` slots, tops up with the
  stalest-fetched movies (by `external_metrics.fetched_at` across all
  OMDb-derived sources: omdb, imdb, metacritic, rotten_tomatoes),
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

    null_count = count_null_backlog()

    Logger.info(
      "RatingsRefresh: Starting daily OMDb refresh (batch_size=#{batch_size}, " <>
        "null_backlog=#{null_count})"
    )

    phase_a_ids = fetch_null_backlog(batch_size)
    phase_a_count = queue_enrichment_jobs(phase_a_ids, %{})

    Logger.info(
      "RatingsRefresh: Phase A queued #{phase_a_count} null-backlog movies " <>
        "(count includes Oban-deduplicated jobs from prior runs)"
    )

    remaining = batch_size - phase_a_count

    if remaining > 0 do
      phase_b_ids = fetch_stale_refresh(remaining)
      phase_b_count = queue_enrichment_jobs(phase_b_ids, %{"force" => true})

      Logger.info(
        "RatingsRefresh: Phase B queued #{phase_b_count} stale-refresh movies " <>
          "(count includes Oban-deduplicated jobs from prior runs)"
      )
    else
      Logger.info("RatingsRefresh: Phase A filled batch, skipping Phase B")
    end

    :ok
  end

  defp count_null_backlog do
    from(m in Movie,
      where: m.import_status == "full",
      where: is_nil(m.omdb_data),
      where: not is_nil(m.imdb_id),
      select: count(m.id)
    )
    |> Repo.one()
  end

  # Phase A: queue movies where omdb_data IS NULL, by tmdb popularity DESC
  defp fetch_null_backlog(limit) do
    from(m in Movie,
      where: m.import_status == "full",
      where: is_nil(m.omdb_data),
      where: not is_nil(m.imdb_id),
      order_by: fragment("(tmdb_data->>'popularity')::float DESC NULLS LAST"),
      limit: ^limit,
      select: m.id
    )
    |> Repo.all()
  end

  # OMDb enrichment writes metrics under these four sources — all must be
  # considered to avoid treating movies with only imdb/metacritic/rt metrics
  # as perpetually stale.
  @omdb_derived_sources ["omdb", "imdb", "metacritic", "rotten_tomatoes"]

  # Phase B: queue movies with omdb_data, stalest external_metrics.fetched_at first
  defp fetch_stale_refresh(limit) do
    stalest_subquery =
      from(em in ExternalMetric,
        where: em.source in @omdb_derived_sources,
        group_by: em.movie_id,
        select: %{movie_id: em.movie_id, last_fetched: max(em.fetched_at)}
      )

    from(m in Movie,
      where: m.import_status == "full",
      where: not is_nil(m.omdb_data),
      where: not is_nil(m.imdb_id),
      left_join: s in subquery(stalest_subquery),
      on: s.movie_id == m.id,
      order_by: [asc_nulls_first: s.last_fetched],
      limit: ^limit,
      select: m.id
    )
    |> Repo.all()
  end

  defp queue_enrichment_jobs([], _extra_args), do: 0

  defp queue_enrichment_jobs(movie_ids, extra_args) do
    Enum.reduce(movie_ids, 0, fn id, count ->
      job = OMDbEnrichmentWorker.new(Map.merge(%{"movie_id" => id}, extra_args))

      case Oban.insert(job) do
        {:ok, _} -> count + 1
        {:error, _} -> count
      end
    end)
  end
end
