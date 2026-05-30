defmodule Cinegraph.Workers.WatchProviderCatalogRefreshWorker do
  @moduledoc """
  Refreshes TMDb watch-provider catalog and supported regions.
  """

  use Oban.Worker,
    queue: :tmdb,
    max_attempts: 3,
    unique: [
      period: 23 * 3600,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Cinegraph.Movies.Availability

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Route all Repo.replica() calls through the dedicated worker pool
    # so this job does not compete with web requests for Repo.Replica connections. (#1007)
    Process.put(:cinegraph_job_repo, Cinegraph.Repo.Worker)
    regions = Map.get(args, "regions", [Availability.default_region()])

    stats = refresh_catalog(regions: regions)

    Logger.info(
      "WatchProviderCatalogRefreshWorker: providers=#{stats.providers} regions=#{stats.regions}"
    )

    {:ok, stats}
  end

  def refresh_catalog(opts \\ []) do
    regions = Keyword.get(opts, :regions, [Availability.default_region()])

    provider_fetch_fun =
      Keyword.get(opts, :provider_fetch_fun, &Cinegraph.Services.TMDb.get_watch_providers/1)

    region_fetch_fun =
      Keyword.get(opts, :region_fetch_fun, &Cinegraph.Services.TMDb.get_watch_provider_regions/0)

    providers =
      Availability.sync_provider_catalog!(regions: regions, fetch_fun: provider_fetch_fun)

    supported_regions = Availability.sync_regions!(fetch_fun: region_fetch_fun)

    %{providers: length(providers), regions: length(supported_regions)}
  end
end
