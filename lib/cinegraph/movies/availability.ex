defmodule Cinegraph.Movies.Availability do
  @moduledoc """
  Stores normalized movie watch-provider availability.

  Session 1 only normalizes already-fetched TMDb payloads. It does not fetch
  from TMDb, enqueue jobs, or wire into the main movie import flow.
  """

  import Ecto.Query, warn: false

  alias Cinegraph.Repo

  alias Cinegraph.Movies.{
    Movie,
    MovieAvailabilityRefresh,
    MovieWatchProvider,
    WatchProvider,
    WatchProviderRegion
  }

  alias Cinegraph.Services.TMDb

  @default_regions ["US"]
  @default_source "tmdb"
  @stale_after_seconds 30 * 24 * 60 * 60

  @doc """
  Syncs the watch-provider catalog from TMDb for the selected regions.
  """
  def sync_provider_catalog!(opts \\ []) do
    regions = opts |> Keyword.get(:regions, @default_regions) |> normalize_regions()
    source = opts |> Keyword.get(:source, @default_source) |> to_string()
    fetched_at = Keyword.get(opts, :fetched_at, now())
    fetch_fun = Keyword.get(opts, :fetch_fun, &TMDb.get_watch_providers/1)

    Enum.flat_map(regions, fn region ->
      case fetch_fun.(watch_region: region) do
        {:ok, %{"results" => providers}} when is_list(providers) ->
          Enum.map(providers, &upsert_catalog_provider!(&1, region, source, fetched_at))

        {:ok, _payload} ->
          []

        {:error, reason} ->
          raise "TMDb watch-provider catalog sync failed for #{region}: #{inspect(reason)}"
      end
    end)
  end

  @doc """
  Syncs supported watch-provider regions from TMDb.
  """
  def sync_regions!(opts \\ []) do
    source = opts |> Keyword.get(:source, @default_source) |> to_string()
    fetched_at = Keyword.get(opts, :fetched_at, now())
    fetch_fun = Keyword.get(opts, :fetch_fun, &TMDb.get_watch_provider_regions/0)

    case fetch_fun.() do
      {:ok, %{"results" => regions}} when is_list(regions) ->
        Enum.map(regions, &upsert_region!(&1, source, fetched_at))

      {:ok, _payload} ->
        []

      {:error, reason} ->
        raise "TMDb watch-provider region sync failed: #{inspect(reason)}"
    end
  end

  @doc """
  Records availability refresh errors for one movie and selected regions.
  """
  def record_availability_error(%Movie{} = movie, regions, reason, opts \\ []) do
    source = opts |> Keyword.get(:source, @default_source) |> to_string()
    regions = normalize_regions(regions)
    fetched_at = Keyword.get(opts, :fetched_at, now())

    stale_after =
      Keyword.get(opts, :stale_after, DateTime.add(fetched_at, @stale_after_seconds, :second))

    Repo.transaction(fn ->
      Enum.map(regions, fn region ->
        upsert_refresh!(%{
          movie_id: movie.id,
          region: region,
          source: source,
          status: "error",
          error_reason: normalize_error_reason(reason),
          fetched_at: fetched_at,
          stale_after: stale_after,
          metadata: %{"error" => inspect(reason)}
        })
      end)
    end)
  end

  @doc """
  Returns true when all selected movie availability regions are still fresh.
  """
  def fresh_for_regions?(movie_id, regions, opts \\ []) do
    source = opts |> Keyword.get(:source, @default_source) |> to_string()
    regions = normalize_regions(regions)
    now = Keyword.get(opts, :now, now())

    fresh_count =
      from(r in MovieAvailabilityRefresh,
        where: r.movie_id == ^movie_id,
        where: r.source == ^source,
        where: r.region in ^regions,
        where: r.stale_after > ^now,
        select: count(r.id)
      )
      |> Repo.one()

    fresh_count == length(regions)
  end

  @doc """
  Lists current movie availability grouped by monetization type.
  """
  def list_movie_availability(movie_id, region \\ "US", opts \\ []) do
    source = opts |> Keyword.get(:source, @default_source) |> to_string()
    region = normalize_region(region)

    rows =
      from(mwp in MovieWatchProvider,
        where: mwp.movie_id == ^movie_id,
        where: mwp.region == ^region,
        where: mwp.source == ^source,
        order_by: [
          asc: mwp.monetization_type,
          asc_nulls_last: mwp.display_priority,
          asc: mwp.id
        ],
        preload: [:watch_provider]
      )
      |> Repo.all()

    MovieWatchProvider.valid_monetization_types()
    |> Map.new(fn type ->
      type_rows =
        rows
        |> Enum.filter(&(&1.monetization_type == type))
        |> Enum.sort_by(&{is_nil(&1.display_priority), &1.display_priority || 999_999})

      {type, type_rows}
    end)
  end

  @doc """
  Returns the freshness row for a movie/region/source, if one exists.
  """
  def availability_freshness(movie_id, region \\ "US", opts \\ []) do
    source = opts |> Keyword.get(:source, @default_source) |> to_string()
    region = normalize_region(region)

    Repo.get_by(MovieAvailabilityRefresh, movie_id: movie_id, region: region, source: source)
  end

  @doc """
  Returns true if an active availability refresh job exists for this movie.
  """
  def availability_refresh_queued?(movie_id, region \\ "US") do
    region = normalize_region(region)
    movie_id = to_string(movie_id)

    from(j in Oban.Job,
      where: j.worker == "Cinegraph.Workers.MovieAvailabilityRefreshWorker",
      where: j.state in ["available", "scheduled", "executing", "retryable"],
      where: fragment("?->>'movie_id' = ?", j.args, ^movie_id),
      where:
        fragment(
          "NOT (? \\? 'regions') OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(?->'regions') AS region(value) WHERE region.value = ?)",
          j.args,
          j.args,
          ^region
        ),
      select: count(j.id) > 0
    )
    |> Repo.one()
  end

  @doc """
  Returns regions with either availability rows or freshness rows for a movie.
  """
  def available_regions(movie_id, opts \\ []) do
    source = opts |> Keyword.get(:source, @default_source) |> to_string()

    availability_regions =
      from(mwp in MovieWatchProvider,
        where: mwp.movie_id == ^movie_id,
        where: mwp.source == ^source,
        select: mwp.region
      )

    refresh_regions =
      from(r in MovieAvailabilityRefresh,
        where: r.movie_id == ^movie_id,
        where: r.source == ^source,
        select: r.region
      )

    (Repo.all(availability_regions) ++ Repo.all(refresh_regions))
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> ["US"]
      regions -> regions
    end
  end

  @doc """
  Stores TMDb watch-provider payloads in normalized availability tables.

  Accepts payloads shaped like:

      %{"results" => %{"US" => %{"flatrate" => [...], "link" => "..."}}}

  Options:

    * `:regions` - region codes to normalize, defaults to `["US"]`
    * `:source` - source identifier, defaults to `"tmdb"`
    * `:fetched_at` - timestamp for deterministic tests
    * `:stale_after` - explicit stale timestamp, defaults to fetched_at + 30 days
  """
  def store_tmdb_watch_providers(%Movie{} = movie, tmdb_payload, opts \\ []) do
    source = opts |> Keyword.get(:source, @default_source) |> to_string()
    regions = opts |> Keyword.get(:regions, @default_regions) |> normalize_regions()
    fetched_at = Keyword.get(opts, :fetched_at, now())

    stale_after =
      Keyword.get(opts, :stale_after, DateTime.add(fetched_at, @stale_after_seconds, :second))

    Repo.transaction(fn ->
      case tmdb_payload do
        %{"results" => results} when is_map(results) ->
          Enum.map(regions, fn region ->
            store_region(movie, results, region, source, fetched_at, stale_after)
          end)

        _ ->
          Enum.map(regions, fn region ->
            replace_region_rows(movie.id, region, source)

            refresh =
              upsert_refresh!(%{
                movie_id: movie.id,
                region: region,
                source: source,
                status: "error",
                error_reason: "invalid_tmdb_watch_providers_payload",
                fetched_at: fetched_at,
                stale_after: stale_after,
                metadata: %{}
              })

            %{
              region: region,
              status: "error",
              refresh: refresh,
              providers: [],
              availabilities: []
            }
          end)
      end
    end)
  end

  defp store_region(movie, results, region, source, fetched_at, stale_after) do
    country_data = Map.get(results, region) || %{}
    tmdb_link = Map.get(country_data, "link")
    {provider_entries, malformed_entries?} = provider_entries(country_data)

    replace_region_rows(movie.id, region, source)

    availabilities =
      Enum.map(provider_entries, fn {monetization_type, provider_data} ->
        provider = upsert_provider!(provider_data, source, fetched_at)

        attrs = %{
          movie_id: movie.id,
          watch_provider_id: provider.id,
          region: region,
          monetization_type: monetization_type,
          display_priority: provider_data["display_priority"],
          tmdb_link: tmdb_link,
          source: source,
          fetched_at: fetched_at,
          stale_after: stale_after,
          metadata: %{"provider_payload" => provider_data}
        }

        %MovieWatchProvider{}
        |> MovieWatchProvider.changeset(attrs)
        |> Repo.insert!()
      end)

    {status, error_reason} =
      cond do
        availabilities != [] -> {"success", nil}
        malformed_entries? -> {"error", "invalid_provider_entries"}
        true -> {"no_results", nil}
      end

    refresh =
      upsert_refresh!(%{
        movie_id: movie.id,
        region: region,
        source: source,
        status: status,
        error_reason: error_reason,
        tmdb_link: tmdb_link,
        fetched_at: fetched_at,
        stale_after: stale_after,
        metadata: %{"region_payload" => country_data}
      })

    %{
      region: region,
      status: status,
      refresh: refresh,
      providers: Enum.map(availabilities, & &1.watch_provider_id),
      availabilities: availabilities
    }
  end

  defp provider_entries(country_data) when is_map(country_data) do
    entries =
      MovieWatchProvider.valid_monetization_types()
      |> Enum.flat_map(fn monetization_type ->
        country_data
        |> Map.get(monetization_type, [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.map(&{monetization_type, &1})
      end)

    valid_entries =
      entries
      |> Enum.filter(fn {_type, provider_data} -> valid_provider?(provider_data) end)
      |> Enum.uniq_by(fn {type, provider_data} -> {type, provider_data["provider_id"]} end)

    {valid_entries, entries != valid_entries}
  end

  defp valid_provider?(%{"provider_id" => provider_id, "provider_name" => provider_name}) do
    not is_nil(provider_id) and is_binary(provider_name) and String.trim(provider_name) != ""
  end

  defp valid_provider?(_provider_data), do: false

  defp replace_region_rows(movie_id, region, source) do
    from(mwp in MovieWatchProvider,
      where: mwp.movie_id == ^movie_id,
      where: mwp.region == ^region,
      where: mwp.source == ^source
    )
    |> Repo.delete_all()
  end

  defp upsert_provider!(provider_data, source, fetched_at) do
    provider_id = provider_data["provider_id"]

    attrs = %{
      source: source,
      source_provider_id: to_string(provider_id),
      tmdb_provider_id: tmdb_provider_id(source, provider_id),
      name: provider_data["provider_name"],
      logo_path: provider_data["logo_path"],
      active: true,
      last_seen_at: fetched_at,
      metadata: %{"provider_payload" => provider_data}
    }

    case Repo.get_by(WatchProvider, source: source, source_provider_id: attrs.source_provider_id) do
      nil ->
        %WatchProvider{}
        |> WatchProvider.changeset(attrs)
        |> Repo.insert!()

      provider ->
        provider
        |> WatchProvider.changeset(attrs)
        |> Repo.update!()
    end
  end

  defp upsert_catalog_provider!(provider_data, region, source, fetched_at) do
    provider_id = provider_data["provider_id"]

    attrs = %{
      source: source,
      source_provider_id: to_string(provider_id),
      tmdb_provider_id: tmdb_provider_id(source, provider_id),
      name: provider_data["provider_name"],
      logo_path: provider_data["logo_path"],
      display_priorities: %{region => provider_data["display_priority"]},
      active: true,
      last_seen_at: fetched_at,
      metadata: %{"provider_payload" => provider_data}
    }

    case Repo.get_by(WatchProvider, source: source, source_provider_id: attrs.source_provider_id) do
      nil ->
        %WatchProvider{}
        |> WatchProvider.changeset(attrs)
        |> Repo.insert!()

      provider ->
        provider
        |> WatchProvider.changeset(%{
          attrs
          | display_priorities:
              Map.merge(provider.display_priorities || %{}, attrs.display_priorities),
            metadata: Map.merge(provider.metadata || %{}, attrs.metadata)
        })
        |> Repo.update!()
    end
  end

  defp upsert_region!(region_data, source, fetched_at) do
    code = region_data["iso_3166_1"]

    attrs = %{
      iso_3166_1: code,
      english_name: region_data["english_name"],
      native_name: region_data["native_name"],
      source: source,
      active: true,
      last_seen_at: fetched_at,
      metadata: %{"region_payload" => region_data}
    }

    case Repo.get_by(WatchProviderRegion, source: source, iso_3166_1: code) do
      nil ->
        %WatchProviderRegion{}
        |> WatchProviderRegion.changeset(attrs)
        |> Repo.insert!()

      region ->
        region
        |> WatchProviderRegion.changeset(attrs)
        |> Repo.update!()
    end
  end

  defp upsert_refresh!(attrs) do
    case Repo.get_by(MovieAvailabilityRefresh,
           movie_id: attrs.movie_id,
           region: attrs.region,
           source: attrs.source
         ) do
      nil ->
        %MovieAvailabilityRefresh{}
        |> MovieAvailabilityRefresh.changeset(attrs)
        |> Repo.insert!()

      refresh ->
        refresh
        |> MovieAvailabilityRefresh.changeset(attrs)
        |> Repo.update!()
    end
  end

  defp normalize_regions(regions) when is_list(regions) do
    regions
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.upcase/1)
  end

  defp normalize_regions(region), do: normalize_regions([region])

  defp normalize_region(region) do
    region
    |> List.wrap()
    |> normalize_regions()
    |> List.first()
    |> Kernel.||("US")
  end

  defp tmdb_provider_id("tmdb", provider_id) when is_integer(provider_id), do: provider_id

  defp tmdb_provider_id("tmdb", provider_id) when is_binary(provider_id),
    do: parse_int(provider_id)

  defp tmdb_provider_id(_source, _provider_id), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_error_reason(reason) do
    reason
    |> inspect()
    |> String.slice(0, 500)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
