defmodule Cinegraph.Movies.AvailabilityBackfill do
  @moduledoc """
  Backfills normalized watch availability from existing `movies.tmdb_data`.

  This module intentionally does not call TMDb. It only reads already-stored
  watch-provider JSON and delegates normalization to `Cinegraph.Movies.Availability`.
  """

  import Ecto.Query, warn: false

  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Availability, Movie, MovieAvailabilityRefresh}

  @default_batch_size 500
  @default_regions ["US"]
  @default_source "tmdb"

  @type stats :: %{
          processed: non_neg_integer(),
          success: non_neg_integer(),
          no_results: non_neg_integer(),
          error: non_neg_integer(),
          skipped: non_neg_integer(),
          last_id: integer() | nil,
          dry_run: boolean()
        }

  @doc """
  Runs an idempotent availability backfill from stored TMDb JSON.

  Options:

    * `:limit` - maximum number of eligible movies to inspect
    * `:batch_size` - query batch size, defaults to 500
    * `:after_id` - resume after this movie id
    * `:regions` - region list, defaults to `["US"]`
    * `:dry_run` - count only; do not write rows
  """
  @spec run(keyword()) :: {:ok, stats()}
  def run(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    batch_size =
      positive_integer!(Keyword.get(opts, :batch_size, @default_batch_size), :batch_size)

    after_id = non_negative_integer!(Keyword.get(opts, :after_id, 0), :after_id)
    regions = opts |> Keyword.get(:regions, @default_regions) |> normalize_regions()
    dry_run? = Keyword.get(opts, :dry_run, false)
    source = opts |> Keyword.get(:source, @default_source) |> to_string()

    stats = %{
      processed: 0,
      success: 0,
      no_results: 0,
      error: 0,
      skipped: 0,
      last_id: nil,
      dry_run: dry_run?
    }

    {:ok, do_run(after_id, limit, batch_size, regions, source, dry_run?, stats)}
  end

  defp do_run(_after_id, 0, _batch_size, _regions, _source, _dry_run?, stats), do: stats

  defp do_run(after_id, limit, batch_size, regions, source, dry_run?, stats) do
    batch_limit = batch_limit(limit, batch_size)

    movies =
      after_id
      |> eligible_query(batch_limit)
      |> Repo.all()

    if movies == [] do
      stats
    else
      stats = Enum.reduce(movies, stats, &process_movie(&1, &2, regions, source, dry_run?))
      remaining_limit = decrement_limit(limit, length(movies))
      last_id = List.last(movies).id

      do_run(last_id, remaining_limit, batch_size, regions, source, dry_run?, stats)
    end
  end

  defp eligible_query(after_id, limit) do
    from(m in Movie,
      where: m.id > ^after_id,
      where: fragment("? \\? 'watch_providers'", m.tmdb_data),
      order_by: [asc: m.id],
      limit: ^limit,
      select: %{id: m.id, tmdb_data: m.tmdb_data}
    )
  end

  defp process_movie(movie, stats, regions, source, dry_run?) do
    stats = %{stats | last_id: movie.id}

    if already_normalized?(movie.id, regions, source) do
      bump(stats, :skipped)
    else
      payload = get_in(movie.tmdb_data || %{}, ["watch_providers"])

      if dry_run? do
        classify_dry_run(stats, payload, regions)
      else
        store_movie(movie, stats, payload, regions, source)
      end
    end
  end

  defp store_movie(movie, stats, payload, regions, source) do
    case Availability.store_tmdb_watch_providers(%Movie{id: movie.id}, payload,
           regions: regions,
           source: source
         ) do
      {:ok, results} ->
        stats
        |> bump(:processed)
        |> bump_statuses(results)

      {:error, _reason} ->
        stats
        |> bump(:processed)
        |> bump(:error)
    end
  rescue
    _error ->
      stats
      |> bump(:processed)
      |> bump(:error)
  end

  defp classify_dry_run(stats, payload, regions) do
    stats = bump(stats, :processed)

    case payload do
      %{"results" => results} when is_map(results) ->
        regions
        |> Enum.map(&dry_run_status(results, &1))
        |> Enum.reduce(stats, fn status, acc -> bump(acc, status) end)

      _ ->
        bump(stats, :error)
    end
  end

  defp dry_run_status(results, region) do
    country_data = Map.get(results, region) || %{}

    has_valid? =
      Cinegraph.Movies.MovieWatchProvider.valid_monetization_types()
      |> Enum.any?(fn type ->
        country_data
        |> Map.get(type, [])
        |> List.wrap()
        |> Enum.any?(&valid_provider_payload?/1)
      end)

    has_malformed? =
      Cinegraph.Movies.MovieWatchProvider.valid_monetization_types()
      |> Enum.any?(fn type ->
        country_data
        |> Map.get(type, [])
        |> List.wrap()
        |> Enum.any?(fn entry -> is_map(entry) and not valid_provider_payload?(entry) end)
      end)

    cond do
      has_valid? -> :success
      has_malformed? -> :error
      true -> :no_results
    end
  end

  defp already_normalized?(movie_id, regions, source) do
    from(r in MovieAvailabilityRefresh,
      where: r.movie_id == ^movie_id,
      where: r.source == ^source,
      where: r.region in ^regions,
      select: count(r.id)
    )
    |> Repo.one()
    |> then(&(&1 == length(regions)))
  end

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp bump_statuses(stats, results) do
    Enum.reduce(results, stats, fn %{status: status}, acc ->
      bump(acc, String.to_existing_atom(status))
    end)
  end

  defp batch_limit(nil, batch_size), do: batch_size
  defp batch_limit(limit, batch_size), do: min(limit, batch_size)

  defp decrement_limit(nil, _count), do: nil
  defp decrement_limit(limit, count), do: max(limit - count, 0)

  defp normalize_regions(regions) when is_binary(regions) do
    regions
    |> String.split(",", trim: true)
    |> normalize_regions()
  end

  defp normalize_regions(regions) when is_list(regions) do
    regions
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.upcase/1)
  end

  defp normalize_regions(region), do: normalize_regions([region])

  defp valid_provider_payload?(%{"provider_id" => provider_id, "provider_name" => provider_name}) do
    not is_nil(provider_id) and is_binary(provider_name) and String.trim(provider_name) != ""
  end

  defp valid_provider_payload?(_entry), do: false

  defp positive_integer!(value, _key) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, key),
    do: raise(ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}")

  defp non_negative_integer!(value, _key) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer!(value, key),
    do: raise(ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}")
end
