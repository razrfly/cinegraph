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
  - `OMDB_DAILY_BATCH_SIZE` env var (default 100_000)
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
    batch_size = Application.get_env(:cinegraph, :omdb_daily_batch_size, 100_000)

    null_count = count_null_backlog()

    Logger.info(
      "RatingsRefresh: Starting daily OMDb refresh (batch_size=#{batch_size}, " <>
        "null_backlog=#{null_count})"
    )

    # Phase A0: 1001-list priority — fill first from movies on the canonical 1001 list
    phase_a0_ids = fetch_1001_priority(batch_size)
    phase_a0_count = queue_enrichment_jobs(phase_a0_ids, %{})

    Logger.info("RatingsRefresh: Phase A0 queued #{phase_a0_count} 1001-list priority movies")

    remaining_after_a0 = batch_size - phase_a0_count

    # Phase A: fill remaining budget with null-backlog movies by popularity
    phase_a_ids = fetch_null_backlog(remaining_after_a0, phase_a0_ids)
    phase_a_count = queue_enrichment_jobs(phase_a_ids, %{})

    Logger.info(
      "RatingsRefresh: Phase A queued #{phase_a_count} null-backlog movies " <>
        "(count includes Oban-deduplicated jobs from prior runs)"
    )

    remaining = remaining_after_a0 - phase_a_count

    if remaining > 0 do
      phase_b_ids = fetch_stale_refresh(remaining)
      phase_b_count = queue_enrichment_jobs(phase_b_ids, %{"force" => true})

      Logger.info(
        "RatingsRefresh: Phase B queued #{phase_b_count} stale-refresh movies " <>
          "(count includes Oban-deduplicated jobs from prior runs)"
      )
    else
      Logger.info("RatingsRefresh: Phase A0+A filled batch, skipping Phase B")
    end

    :ok
  end

  # Subquery for movies with a fetch_attempt record within the 90-day cooldown window.
  defp recently_checked_subquery do
    cutoff = DateTime.add(DateTime.utc_now(), -90 * 24 * 3600, :second)

    from(em in ExternalMetric,
      where: em.source == "omdb" and em.metric_type == "fetch_attempt",
      where: em.fetched_at > ^cutoff,
      select: em.movie_id
    )
  end

  defp count_null_backlog do
    from(m in Movie,
      where: m.import_status == "full",
      where: is_nil(m.omdb_data),
      where: not is_nil(m.imdb_id),
      where: m.id not in subquery(recently_checked_subquery()),
      select: count(m.id)
    )
    |> Repo.one()
  end

  # Phase A0: 1001-list priority — queue movies on the canonical 1001 list first.
  defp fetch_1001_priority(limit) do
    from(m in Movie,
      where: m.import_status == "full",
      where: is_nil(m.omdb_data),
      where: not is_nil(m.imdb_id),
      where: fragment("? \\? '1001_movies'", m.canonical_sources),
      where: m.id not in subquery(recently_checked_subquery()),
      order_by: fragment("(tmdb_data->>'popularity')::float DESC NULLS LAST"),
      limit: ^limit,
      select: m.id
    )
    |> Repo.all()
  end

  # Phase A: queue movies where omdb_data IS NULL, by tmdb popularity DESC,
  # excluding movies with a recent fetch_attempt record (90-day cooldown)
  # and any IDs already queued by Phase A0.
  defp fetch_null_backlog(0, _exclude_ids), do: []

  defp fetch_null_backlog(limit, exclude_ids) do
    from(m in Movie,
      where: m.import_status == "full",
      where: is_nil(m.omdb_data),
      where: not is_nil(m.imdb_id),
      where: m.id not in ^exclude_ids,
      where: m.id not in subquery(recently_checked_subquery()),
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
        {:ok, _} ->
          count + 1

        {:error, reason} ->
          Logger.error(
            "RatingsRefresh: failed to insert OMDb job for movie_id=#{id} " <>
              "extra_args=#{inspect(extra_args)} error=#{inspect(reason)}"
          )

          count
      end
    end)
  end
end
