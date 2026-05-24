defmodule Cinegraph.Workers.NowPlayingSweeper do
  @moduledoc """
  Polls TMDB /movie/now_playing across five regions every 6 hours and stamps
  both `now_playing_last_seen` (global) and `now_playing_region_last_seen`
  (per-region JSONB map) on matched movies. Films that vanish from all regions
  for more than 3 days go stale naturally — no explicit clearing needed.

  The per-region map is merged via Postgres `||` so a failed region poll does
  not clear timestamps for other regions — they age out naturally.

  New TMDB IDs not yet in the DB are queued for TMDbDetailsWorker import;
  they will be stamped on the next sweep once fully imported.

  Schedule: `0 */6 * * *` (every 6 hours). Unique per hour so double-fires
  from deploys don't stack.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 2,
    unique: [period: 3600],
    priority: 3

  import Ecto.Query

  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo
  alias Cinegraph.Services.TMDb.Extended, as: TMDbExtended
  alias Cinegraph.Workers.TMDbDetailsWorker

  require Logger

  @regions ["US", "GB", "DE", "FR", "PL"]
  @max_pages 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    {region_map, pages_fetched, region_errors} = collect_now_playing_ids()
    {stamped, queued_imports} = process_region_ids(region_map, now)

    Logger.info(
      "NowPlayingSweeper: stamped=#{stamped} queued_imports=#{queued_imports} " <>
        "region_errors=#{inspect(region_errors)} pages_fetched=#{pages_fetched}"
    )

    {:ok,
     %{
       stamped: stamped,
       queued_imports: queued_imports,
       region_errors: region_errors,
       pages_fetched: pages_fetched
     }}
  end

  # Fetch TMDB IDs keyed by region, tolerating per-region failures.
  defp collect_now_playing_ids do
    Enum.reduce(@regions, {%{}, 0, []}, fn region, {region_map, pages, errors} ->
      result =
        try do
          fetch_region(region)
        rescue
          e -> {:error, Exception.message(e)}
        end

      case result do
        {:ok, region_ids, region_pages} ->
          {Map.put(region_map, region, region_ids), pages + region_pages, errors}

        {:error, reason} ->
          Logger.warning("NowPlayingSweeper: region #{region} failed — #{inspect(reason)}")
          {region_map, pages, [region | errors]}
      end
    end)
  end

  defp fetch_region(region) do
    Enum.reduce_while(1..@max_pages, {:ok, MapSet.new(), 0}, fn page, {:ok, acc_ids, acc_pages} ->
      case TMDbExtended.get_now_playing_movies(page: page, region: region) do
        {:ok, %{"results" => results, "total_pages" => total_pages}} ->
          ids =
            results
            |> Enum.map(& &1["id"])
            |> Enum.reject(&is_nil/1)
            |> MapSet.new()

          merged = MapSet.union(acc_ids, ids)
          fetched_pages = acc_pages + 1

          if page >= total_pages or page >= @max_pages do
            {:halt, {:ok, merged, fetched_pages}}
          else
            {:cont, {:ok, merged, fetched_pages}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp process_region_ids(region_map, _now) when map_size(region_map) == 0, do: {0, 0}

  defp process_region_ids(region_map, now) do
    all_ids =
      region_map
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      |> MapSet.to_list()

    existing =
      from(m in Movie, where: m.tmdb_id in ^all_ids, select: {m.tmdb_id, m.id})
      |> Repo.all()

    existing_map = Map.new(existing)
    existing_tmdb_ids = Map.keys(existing_map)
    now_iso = DateTime.to_iso8601(now)

    {:ok, stamped} =
      Repo.transaction(fn ->
        {stamped, _} =
          from(m in Movie, where: m.tmdb_id in ^existing_tmdb_ids)
          |> Repo.update_all(set: [now_playing_last_seen: now])

        Enum.each(region_map, fn {region, region_ids} ->
          region_tmdb_ids =
            region_ids
            |> MapSet.to_list()
            |> Enum.filter(&Map.has_key?(existing_map, &1))

          unless region_tmdb_ids == [] do
            region_data = %{region => now_iso}

            from(m in Movie,
              where: m.tmdb_id in ^region_tmdb_ids,
              update: [
                set: [
                  now_playing_region_last_seen:
                    fragment(
                      "COALESCE(now_playing_region_last_seen, '{}'::jsonb) || ?",
                      type(^region_data, :map)
                    )
                ]
              ]
            )
            |> Repo.update_all([])
          end
        end)

        stamped
      end)

    unknown_ids = all_ids -- existing_tmdb_ids

    queued_imports =
      unknown_ids
      |> Enum.map(fn tmdb_id ->
        TMDbDetailsWorker.new(%{"tmdb_id" => tmdb_id, "source" => "now_playing_sweep"})
      end)
      |> Oban.insert_all()
      |> length()

    {stamped, queued_imports}
  end
end
