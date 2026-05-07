defmodule Cinegraph.Health.Drift.Availability do
  @moduledoc """
  Drift checks for movie watch availability freshness and provider catalog state.
  """

  import Ecto.Query, warn: false

  alias Cinegraph.Health.Drift

  alias Cinegraph.Movies.{
    Availability,
    Movie,
    MovieAvailabilityRefresh,
    WatchProvider,
    WatchProviderRegion
  }

  alias Cinegraph.Repo

  @cache_ttl :timer.minutes(5)
  @example_limit 10
  @catalog_stale_days 7

  @doc """
  Runs every availability drift check and returns normalized drift results.
  """
  def all(opts \\ []) do
    Drift.run_all([
      fn -> availability_missing(opts) end,
      fn -> availability_stale(opts) end,
      fn -> availability_fetch_errors(opts) end,
      fn -> availability_provider_catalog_stale(opts) end
    ])
  end

  @doc """
  Reports full TMDb movies missing an availability refresh row for the default region.
  """
  def availability_missing(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:availability, :availability_missing, limit}, @cache_ttl, fn ->
      base = full_movies_with_tmdb()
      region = Availability.default_region()

      missing =
        from(m in base,
          left_join: r in MovieAvailabilityRefresh,
          on: r.movie_id == m.id and r.region == ^region and r.source == "tmdb",
          where: is_nil(r.id)
        )

      total = Repo.replica().one(from(m in base, select: count(m.id))) || 0
      affected = Repo.replica().one(from(m in missing, select: count(m.id))) || 0

      examples =
        missing
        |> order_by([m], asc: m.id)
        |> limit(^limit)
        |> select([m], %{
          id: m.id,
          title: m.title,
          reason: fragment("? || '/tmdb availability refresh row missing'", ^region)
        })
        |> Repo.replica().all()

      Drift.result(:availability, :availability_missing, total, affected, examples)
    end)
  end

  @doc """
  Reports default-region availability refresh rows whose stale deadline has passed.
  """
  def availability_stale(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:availability, :availability_stale, limit}, @cache_ttl, fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      region = Availability.default_region()

      base =
        from(r in MovieAvailabilityRefresh,
          where: r.region == ^region,
          where: r.source == "tmdb"
        )

      stale =
        from(r in base,
          join: m in Movie,
          on: m.id == r.movie_id,
          where: r.stale_after < ^now
        )

      total = Repo.replica().one(from(r in base, select: count(r.id))) || 0
      affected = Repo.replica().one(from(r in stale, select: count(r.id))) || 0

      examples =
        stale
        |> order_by([r, _m], asc: r.stale_after)
        |> limit(^limit)
        |> select([r, m], %{
          id: m.id,
          title: m.title,
          stale_after: r.stale_after,
          reason: "availability stale"
        })
        |> Repo.replica().all()

      Drift.result(:availability, :availability_stale, total, affected, examples)
    end)
  end

  @doc """
  Reports default-region availability refresh rows currently in an error state.
  """
  def availability_fetch_errors(opts \\ []) do
    limit = Keyword.get(opts, :limit, @example_limit)

    Drift.cached({:availability, :availability_fetch_errors, limit}, @cache_ttl, fn ->
      base =
        from(r in MovieAvailabilityRefresh,
          where: r.region == ^Availability.default_region(),
          where: r.source == "tmdb"
        )

      errors =
        from(r in base,
          join: m in Movie,
          on: m.id == r.movie_id,
          where: r.status == "error"
        )

      total = Repo.replica().one(from(r in base, select: count(r.id))) || 0
      affected = Repo.replica().one(from(r in errors, select: count(r.id))) || 0

      examples =
        errors
        |> order_by([r, _m], desc: r.fetched_at)
        |> limit(^limit)
        |> select([r, m], %{
          id: m.id,
          title: m.title,
          error_reason: r.error_reason,
          reason: "availability refresh error"
        })
        |> Repo.replica().all()

      Drift.result(:availability, :availability_fetch_errors, total, affected, examples)
    end)
  end

  @doc """
  Reports stale or missing provider catalog and supported-region metadata.
  """
  def availability_provider_catalog_stale(_opts \\ []) do
    Drift.cached({:availability, :availability_provider_catalog_stale}, @cache_ttl, fn ->
      cutoff = DateTime.utc_now() |> DateTime.add(-@catalog_stale_days * 86_400, :second)

      provider_count = Repo.replica().one(from(p in WatchProvider, select: count(p.id))) || 0
      region_count = Repo.replica().one(from(r in WatchProviderRegion, select: count(r.id))) || 0

      stale_providers =
        Repo.replica().one(
          from(p in WatchProvider,
            where: is_nil(p.last_seen_at) or p.last_seen_at < ^cutoff,
            select: count(p.id)
          )
        ) || 0

      stale_regions =
        Repo.replica().one(
          from(r in WatchProviderRegion,
            where: is_nil(r.last_seen_at) or r.last_seen_at < ^cutoff,
            select: count(r.id)
          )
        ) || 0

      missing_catalog? = provider_count == 0 or region_count == 0
      total = max(provider_count + region_count, 1)

      affected =
        min(stale_providers + stale_regions + if(missing_catalog?, do: 1, else: 0), total)

      examples =
        if missing_catalog? do
          [
            %{
              id: nil,
              reason: "provider catalog or supported regions have not been synced"
            }
          ]
        else
          []
        end

      Drift.result(:availability, :availability_provider_catalog_stale, total, affected, examples)
    end)
  end

  # Canonical-list movies that we've fully imported from TMDb. Drift
  # checks in this domain measure availability coverage against this
  # population, not the bulk-ingest long-tail (#896 Phase 1.4) — most
  # non-canonical movies legitimately have no streaming availability
  # data and reporting against them was a measurement artifact.
  defp full_movies_with_tmdb do
    from(m in Movie,
      where: m.import_status == "full",
      where: not is_nil(m.tmdb_id),
      where: fragment("? != '{}'::jsonb", m.canonical_sources)
    )
  end
end
