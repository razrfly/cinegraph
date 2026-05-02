defmodule Cinegraph.Maintenance.RefreshAvailability do
  @moduledoc """
  Enqueues movie availability refresh jobs for missing or stale availability rows.
  """

  import Ecto.Query, warn: false

  alias Cinegraph.Movies.{Availability, Movie, MovieAvailabilityRefresh}
  alias Cinegraph.Repo
  alias Cinegraph.Workers.MovieAvailabilityRefreshWorker

  require Logger

  @default_limit 5_000
  @insert_chunk_size 500

  def run(opts \\ []) do
    try do
      limit = Keyword.get(opts, :limit, @default_limit)
      dry_run? = Keyword.get(opts, :dry_run, false)
      requested_regions = Keyword.get(opts, :regions, Availability.configured_regions())
      now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))

      regions = normalize_regions(requested_regions)
      ids = candidate_ids(limit, now, regions)
      found = length(ids)

      if dry_run? do
        {:ok, %{found: found, enqueued: 0, failed: 0, dry_run: true}}
      else
        {enqueued, failed} = enqueue(ids, refresh_regions_arg(requested_regions))
        {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false}}
      end
    rescue
      error -> {:error, error}
    end
  end

  defp candidate_ids(limit, now, regions) do
    []
    |> take_phase(limit, fn remaining, excluded ->
      missing_with_existing_json(remaining, excluded, regions)
    end)
    |> take_phase(limit, fn remaining, excluded -> missing_any(remaining, excluded, regions) end)
    |> take_phase(limit, fn remaining, excluded ->
      priority_stale(remaining, excluded, now, regions)
    end)
    |> take_phase(limit, fn remaining, excluded ->
      remaining_stale(remaining, excluded, now, regions)
    end)
  end

  defp take_phase(ids, limit, _fun) when length(ids) >= limit, do: Enum.take(ids, limit)

  defp take_phase(ids, limit, fun) do
    remaining = limit - length(ids)
    excluded = ids

    ids ++ fun.(remaining, excluded)
  end

  defp missing_with_existing_json(limit, excluded, regions) do
    missing_base(excluded, regions)
    |> where([m], fragment("? \\? 'watch_providers'", m.tmdb_data))
    |> order_by([m], asc: m.id)
    |> limit(^limit)
    |> select([m], m.id)
    |> Repo.all()
  end

  defp missing_any(limit, excluded, regions) do
    missing_base(excluded, regions)
    |> order_by([m], asc: m.id)
    |> limit(^limit)
    |> select([m], m.id)
    |> Repo.all()
  end

  defp missing_base(excluded, regions) do
    from(m in Movie,
      left_join: r in MovieAvailabilityRefresh,
      on: r.movie_id == m.id and r.region in ^regions and r.source == "tmdb",
      where: m.import_status == "full",
      where: not is_nil(m.tmdb_id),
      where: m.id not in ^excluded,
      group_by: m.id,
      having: count(r.id) < ^length(regions)
    )
  end

  defp priority_stale(limit, excluded, now, regions) do
    stale_base(excluded, now, regions)
    |> where(
      [m, r],
      fragment("? != '{}'::jsonb", m.canonical_sources) or m.release_date >= ^recent_cutoff()
    )
    |> distinct([m, _r], m.id)
    |> order_by([m, r], asc: r.stale_after)
    |> limit(^limit)
    |> select([m, _r], m.id)
    |> Repo.all()
  end

  defp remaining_stale(limit, excluded, now, regions) do
    stale_base(excluded, now, regions)
    |> distinct([m, _r], m.id)
    |> order_by([_m, r], asc: r.stale_after)
    |> limit(^limit)
    |> select([m, _r], m.id)
    |> Repo.all()
  end

  defp stale_base(excluded, now, regions) do
    from(m in Movie,
      join: r in MovieAvailabilityRefresh,
      on: r.movie_id == m.id and r.region in ^regions and r.source == "tmdb",
      where: m.import_status == "full",
      where: not is_nil(m.tmdb_id),
      where: m.id not in ^excluded,
      where: r.stale_after < ^now
    )
  end

  defp recent_cutoff, do: Date.utc_today() |> Date.add(-365 * 2)

  defp enqueue(ids, regions) do
    ids
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, failed} ->
      jobs =
        Enum.map(chunk, fn id ->
          MovieAvailabilityRefreshWorker.new(%{
            "movie_id" => id,
            "force" => false,
            "source" => "scheduled"
          })
          |> maybe_put_regions(regions)
        end)

      try do
        case Oban.insert_all(jobs) do
          {:ok, inserted} when is_list(inserted) ->
            {ok + length(inserted), failed}

          inserted when is_list(inserted) ->
            {ok + length(inserted), failed}

          other ->
            Logger.error("RefreshAvailability: Oban.insert_all returned #{inspect(other)}")
            {ok, failed + length(chunk)}
        end
      rescue
        error ->
          Logger.error(
            "RefreshAvailability: failed to enqueue #{length(chunk)} jobs: #{Exception.message(error)}"
          )

          {ok, failed + length(chunk)}
      end
    end)
  end

  defp maybe_put_regions(job, :all), do: job

  defp maybe_put_regions(%Ecto.Changeset{} = changeset, regions) do
    args = Ecto.Changeset.get_field(changeset, :args) || %{}
    Ecto.Changeset.put_change(changeset, :args, Map.put(args, "regions", regions))
  end

  defp refresh_regions_arg(:all), do: :all
  defp refresh_regions_arg(regions), do: normalize_regions(regions)

  defp normalize_regions(:all), do: [Availability.default_region()]

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
    |> Enum.uniq()
    |> case do
      [] -> [Availability.default_region()]
      normalized -> normalized
    end
  end

  defp normalize_regions(region), do: normalize_regions([region])
end
