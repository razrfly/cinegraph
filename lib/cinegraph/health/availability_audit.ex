defmodule Cinegraph.Health.AvailabilityAudit do
  @moduledoc """
  Operational audit for movie watch availability coverage and freshness.
  """

  import Ecto.Query, warn: false

  alias Cinegraph.Movies.{
    Availability,
    Movie,
    MovieAvailabilityRefresh,
    WatchProvider,
    WatchProviderRegion
  }

  alias Cinegraph.Repo

  @availability_workers [
    "Cinegraph.Workers.MovieAvailabilityRefreshWorker",
    "Cinegraph.Workers.WatchProviderCatalogRefreshWorker",
    "Cinegraph.Workers.AvailabilityRefreshSweeper"
  ]

  @queue_states ~w(available scheduled executing retryable completed discarded cancelled)

  def audit(opts \\ []) do
    region = opts |> Keyword.get(:region, Availability.default_region()) |> normalize_region()
    limit = opts |> Keyword.get(:limit, 10) |> normalize_positive_integer(10)
    stale_days = opts |> Keyword.get(:stale_days, 30) |> normalize_positive_integer(30)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_cutoff = DateTime.add(now, -stale_days * 86_400, :second)

    %{
      generated_at: DateTime.to_iso8601(now),
      region: region,
      summary: summary(region),
      coverage: coverage(region),
      freshness: freshness(region, now, stale_cutoff),
      errors: errors(region, limit),
      catalog: catalog(now),
      queues: queues(),
      examples: examples(region, limit, now),
      recommended_commands: recommended_commands(region)
    }
  end

  defp summary(region) do
    %{
      full_movies_with_tmdb: full_movies_with_tmdb_count(),
      movies_with_raw_watch_providers: raw_watch_provider_count(),
      movies_with_any_normalized_availability: any_normalized_count(),
      movies_with_region_refresh: region_refresh_count(region),
      movies_with_non_default_region_availability: non_default_region_count()
    }
  end

  defp coverage(region) do
    total = full_movies_with_tmdb_count()

    %{
      raw_tmdb_pct: pct(raw_watch_provider_count(), total),
      normalized_pct: pct(any_normalized_count(), total),
      region_refresh_pct: pct(region_refresh_count(region), total),
      multi_region_normalized_pct: pct(non_default_region_count(), total)
    }
  end

  defp freshness(region, now, stale_cutoff) do
    base =
      from(r in MovieAvailabilityRefresh,
        where: r.region == ^region,
        where: r.source == "tmdb"
      )

    %{
      stale_days: div(DateTime.diff(now, stale_cutoff, :second), 86_400),
      stale_refresh_rows:
        Repo.replica().one(from(r in base, where: r.stale_after < ^now, select: count(r.id))) || 0,
      old_refresh_rows:
        Repo.replica().one(
          from(r in base, where: r.fetched_at < ^stale_cutoff, select: count(r.id))
        ) || 0,
      oldest_stale_after: iso(Repo.replica().one(from(r in base, select: min(r.stale_after)))),
      newest_fetched_at: iso(Repo.replica().one(from(r in base, select: max(r.fetched_at))))
    }
  end

  defp errors(region, limit) do
    base =
      from(r in MovieAvailabilityRefresh,
        where: r.region == ^region,
        where: r.source == "tmdb",
        where: r.status == "error"
      )

    grouped =
      from(r in base,
        group_by: r.error_reason,
        order_by: [desc: count(r.id)],
        limit: ^limit,
        select: %{error_reason: r.error_reason, count: count(r.id)}
      )
      |> Repo.replica().all()
      |> Enum.map(fn row -> %{row | error_reason: display_error_reason(row.error_reason)} end)

    %{
      current_error_rows: Repo.replica().one(from(r in base, select: count(r.id))) || 0,
      grouped_by_reason: grouped
    }
  end

  defp catalog(now) do
    cutoff = DateTime.add(now, -7 * 86_400, :second)

    provider_count = Repo.replica().one(from(p in WatchProvider, select: count(p.id))) || 0
    region_count = Repo.replica().one(from(r in WatchProviderRegion, select: count(r.id))) || 0

    oldest_provider_seen_at =
      Repo.replica().one(from(p in WatchProvider, select: min(p.last_seen_at)))

    newest_provider_seen_at =
      Repo.replica().one(from(p in WatchProvider, select: max(p.last_seen_at)))

    oldest_region_seen_at =
      Repo.replica().one(from(r in WatchProviderRegion, select: min(r.last_seen_at)))

    newest_region_seen_at =
      Repo.replica().one(from(r in WatchProviderRegion, select: max(r.last_seen_at)))

    stale_provider_count =
      Repo.replica().one(
        from(p in WatchProvider,
          where: is_nil(p.last_seen_at) or p.last_seen_at < ^cutoff,
          select: count(p.id)
        )
      ) || 0

    stale_region_count =
      Repo.replica().one(
        from(r in WatchProviderRegion,
          where: is_nil(r.last_seen_at) or r.last_seen_at < ^cutoff,
          select: count(r.id)
        )
      ) || 0

    %{
      provider_count: provider_count,
      region_count: region_count,
      oldest_provider_seen_at: iso(oldest_provider_seen_at),
      newest_provider_seen_at: iso(newest_provider_seen_at),
      oldest_region_seen_at: iso(oldest_region_seen_at),
      newest_region_seen_at: iso(newest_region_seen_at),
      stale_provider_count: stale_provider_count,
      stale_region_count: stale_region_count,
      missing_catalog: provider_count == 0 or region_count == 0
    }
  end

  defp queues do
    rows =
      from(j in Oban.Job,
        where: j.worker in ^@availability_workers,
        where: j.state in ^@queue_states,
        group_by: [j.worker, j.state],
        select: {j.worker, j.state, count(j.id)}
      )
      |> Repo.replica().all()

    Map.new(@availability_workers, fn worker ->
      counts =
        @queue_states
        |> Map.new(fn state ->
          count =
            rows
            |> Enum.find_value(0, fn
              {^worker, ^state, count} -> count
              _ -> nil
            end)

          {state, count}
        end)

      {worker, counts}
    end)
  end

  defp examples(region, limit, now) do
    %{
      raw_but_not_normalized: raw_but_not_normalized_examples(region, limit),
      raw_multi_region_but_default_only_normalized:
        raw_multi_region_default_only_examples(region, limit),
      missing_region_refresh: missing_region_refresh_examples(region, limit),
      stale_refreshes: stale_examples(region, limit, now),
      error_refreshes: error_examples(region, limit)
    }
  end

  defp raw_but_not_normalized_examples(region, limit) do
    reason = "raw watch_providers present but #{region}/tmdb refresh row missing"

    from(m in full_movies_with_tmdb(),
      where: fragment("? \\? 'watch_providers'", m.tmdb_data),
      where:
        not exists(
          from(r in MovieAvailabilityRefresh,
            where: r.movie_id == parent_as(:movie).id,
            where: r.region == ^region,
            where: r.source == "tmdb"
          )
        ),
      order_by: [asc: m.id],
      limit: ^limit,
      select: %{
        id: m.id,
        title: m.title,
        reason: ^reason
      }
    )
    |> Repo.replica().all()
  end

  defp raw_multi_region_default_only_examples(region, limit) do
    reason = "raw payload has multiple regions but only #{region} normalized"

    from(m in full_movies_with_tmdb(),
      where: fragment("jsonb_typeof(? #> '{watch_providers,results}') = 'object'", m.tmdb_data),
      where:
        fragment(
          "(SELECT count(*) FROM jsonb_object_keys(? #> '{watch_providers,results}')) > 1",
          m.tmdb_data
        ),
      where:
        exists(
          from(r in MovieAvailabilityRefresh,
            where: r.movie_id == parent_as(:movie).id,
            where: r.region == ^region,
            where: r.source == "tmdb"
          )
        ),
      where:
        not exists(
          from(r in MovieAvailabilityRefresh,
            where: r.movie_id == parent_as(:movie).id,
            where: r.region != ^region,
            where: r.source == "tmdb"
          )
        ),
      order_by: [asc: m.id],
      limit: ^limit,
      select: %{
        id: m.id,
        title: m.title,
        reason: ^reason
      }
    )
    |> Repo.replica().all()
  end

  defp missing_region_refresh_examples(region, limit) do
    reason = "#{region}/tmdb availability refresh row missing"

    from(m in full_movies_with_tmdb(),
      where:
        not exists(
          from(r in MovieAvailabilityRefresh,
            where: r.movie_id == parent_as(:movie).id,
            where: r.region == ^region,
            where: r.source == "tmdb"
          )
        ),
      order_by: [asc: m.id],
      limit: ^limit,
      select: %{
        id: m.id,
        title: m.title,
        reason: ^reason
      }
    )
    |> Repo.replica().all()
  end

  defp stale_examples(region, limit, now) do
    from(r in MovieAvailabilityRefresh,
      join: m in Movie,
      on: m.id == r.movie_id,
      where: r.region == ^region,
      where: r.source == "tmdb",
      where: r.stale_after < ^now,
      order_by: [asc: r.stale_after],
      limit: ^limit,
      select: %{
        id: m.id,
        title: m.title,
        stale_after: r.stale_after,
        reason: "availability stale"
      }
    )
    |> Repo.replica().all()
    |> Enum.map(&serialize_dates/1)
  end

  defp error_examples(region, limit) do
    from(r in MovieAvailabilityRefresh,
      join: m in Movie,
      on: m.id == r.movie_id,
      where: r.region == ^region,
      where: r.source == "tmdb",
      where: r.status == "error",
      order_by: [desc: r.fetched_at],
      limit: ^limit,
      select: %{
        id: m.id,
        title: m.title,
        error_reason: r.error_reason,
        reason: "availability refresh error"
      }
    )
    |> Repo.replica().all()
    |> Enum.map(fn row -> %{row | error_reason: display_error_reason(row.error_reason)} end)
  end

  defp recommended_commands(region) do
    [
      "mix cinegraph.prod.drift availability --json",
      "mix cinegraph.prod.audit.availability --json --region #{region}",
      "mix cinegraph.prod.movies.backfill_availability --dry-run --limit 100 --json",
      "mix cinegraph.prod.queues --json",
      "mix cinegraph.prod.audit.queue_failures --worker Cinegraph.Workers.MovieAvailabilityRefreshWorker --json",
      "mix cinegraph.prod.audit.queue_failures --worker Cinegraph.Workers.WatchProviderCatalogRefreshWorker --json"
    ]
  end

  defp full_movies_with_tmdb do
    from(m in Movie, as: :movie, where: m.import_status == "full", where: not is_nil(m.tmdb_id))
  end

  defp full_movies_with_tmdb_count do
    Repo.replica().one(from(m in full_movies_with_tmdb(), select: count(m.id))) || 0
  end

  defp raw_watch_provider_count do
    Repo.replica().one(
      from(m in full_movies_with_tmdb(),
        where: fragment("? \\? 'watch_providers'", m.tmdb_data),
        select: count(m.id)
      )
    ) || 0
  end

  defp any_normalized_count do
    Repo.replica().one(
      from(m in full_movies_with_tmdb(),
        where:
          exists(
            from(r in MovieAvailabilityRefresh,
              where: r.movie_id == parent_as(:movie).id,
              where: r.source == "tmdb"
            )
          ),
        select: count(m.id)
      )
    ) || 0
  end

  defp region_refresh_count(region) do
    Repo.replica().one(
      from(m in full_movies_with_tmdb(),
        where:
          exists(
            from(r in MovieAvailabilityRefresh,
              where: r.movie_id == parent_as(:movie).id,
              where: r.region == ^region,
              where: r.source == "tmdb"
            )
          ),
        select: count(m.id)
      )
    ) || 0
  end

  defp non_default_region_count do
    default_region = Availability.default_region()

    Repo.replica().one(
      from(m in full_movies_with_tmdb(),
        where:
          exists(
            from(r in MovieAvailabilityRefresh,
              where: r.movie_id == parent_as(:movie).id,
              where: r.region != ^default_region,
              where: r.source == "tmdb"
            )
          ),
        select: count(m.id)
      )
    ) || 0
  end

  defp pct(_count, 0), do: 0.0
  defp pct(count, total), do: Float.round(count * 100.0 / total, 2)

  defp normalize_region(region) when is_binary(region) do
    region
    |> String.trim()
    |> String.upcase()
    |> case do
      <<region::binary-size(2)>> -> region
      _ -> Availability.default_region()
    end
  end

  defp normalize_region(_), do: Availability.default_region()

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_, default), do: default

  defp serialize_dates(map) do
    Map.new(map, fn
      {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
      {key, value} -> {key, value}
    end)
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp display_error_reason(nil), do: nil

  defp display_error_reason(reason) when is_binary(reason) do
    case Jason.decode(reason) do
      {:ok, decoded} when is_binary(decoded) -> decoded
      _ -> reason
    end
  end
end
