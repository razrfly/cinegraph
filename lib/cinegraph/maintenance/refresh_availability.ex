defmodule Cinegraph.Maintenance.RefreshAvailability do
  @moduledoc """
  Enqueues movie availability refresh jobs for missing or stale availability rows.
  """

  import Ecto.Query, warn: false

  alias Cinegraph.Movies.{Movie, MovieAvailabilityRefresh}
  alias Cinegraph.Repo
  alias Cinegraph.Workers.MovieAvailabilityRefreshWorker

  require Logger

  @default_limit 5_000
  @default_regions ["US"]

  def run(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    dry_run? = Keyword.get(opts, :dry_run, false)
    regions = Keyword.get(opts, :regions, @default_regions)
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))

    ids = candidate_ids(limit, now)
    found = length(ids)

    if dry_run? do
      {:ok, %{found: found, enqueued: 0, failed: 0, dry_run: true}}
    else
      {enqueued, failed} = enqueue(ids, regions)
      {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false}}
    end
  end

  defp candidate_ids(limit, now) do
    []
    |> take_phase(limit, &missing_with_existing_json/2)
    |> take_phase(limit, &missing_any/2)
    |> take_phase(limit, fn remaining, excluded -> priority_stale(remaining, excluded, now) end)
    |> take_phase(limit, fn remaining, excluded -> remaining_stale(remaining, excluded, now) end)
  end

  defp take_phase(ids, limit, _fun) when length(ids) >= limit, do: Enum.take(ids, limit)

  defp take_phase(ids, limit, fun) do
    remaining = limit - length(ids)
    excluded = ids

    ids ++ fun.(remaining, excluded)
  end

  defp missing_with_existing_json(limit, excluded) do
    missing_base(excluded)
    |> where([m], fragment("? \\? 'watch_providers'", m.tmdb_data))
    |> order_by([m], asc: m.id)
    |> limit(^limit)
    |> select([m], m.id)
    |> Repo.all()
  end

  defp missing_any(limit, excluded) do
    missing_base(excluded)
    |> order_by([m], asc: m.id)
    |> limit(^limit)
    |> select([m], m.id)
    |> Repo.all()
  end

  defp missing_base(excluded) do
    from(m in Movie,
      where: m.import_status == "full",
      where: not is_nil(m.tmdb_id),
      where: m.id not in ^excluded,
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM movie_availability_refreshes r WHERE r.movie_id = ? AND r.region = 'US' AND r.source = 'tmdb')",
          m.id
        )
    )
  end

  defp priority_stale(limit, excluded, now) do
    stale_base(excluded, now)
    |> where(
      [m, r],
      fragment("? != '{}'::jsonb", m.canonical_sources) or m.release_date >= ^recent_cutoff()
    )
    |> order_by([m, r], asc: r.stale_after)
    |> limit(^limit)
    |> select([m, _r], m.id)
    |> Repo.all()
  end

  defp remaining_stale(limit, excluded, now) do
    stale_base(excluded, now)
    |> order_by([_m, r], asc: r.stale_after)
    |> limit(^limit)
    |> select([m, _r], m.id)
    |> Repo.all()
  end

  defp stale_base(excluded, now) do
    from(m in Movie,
      join: r in MovieAvailabilityRefresh,
      on: r.movie_id == m.id and r.region == "US" and r.source == "tmdb",
      where: m.import_status == "full",
      where: not is_nil(m.tmdb_id),
      where: m.id not in ^excluded,
      where: r.stale_after < ^now
    )
  end

  defp recent_cutoff, do: Date.utc_today() |> Date.add(-365 * 2)

  defp enqueue(ids, regions) do
    Enum.reduce(ids, {0, 0}, fn id, {ok, failed} ->
      job =
        MovieAvailabilityRefreshWorker.new(%{
          "movie_id" => id,
          "regions" => regions,
          "force" => false,
          "source" => "scheduled"
        })

      case Oban.insert(job) do
        {:ok, _job} ->
          {ok + 1, failed}

        {:error, %Ecto.Changeset{errors: [args: {"has already been taken", _}]}} ->
          {ok + 1, failed}

        {:error, reason} ->
          Logger.error(
            "RefreshAvailability: failed to enqueue movie_id=#{id}: #{inspect(reason)}"
          )

          {ok, failed + 1}
      end
    end)
  end
end
