defmodule Cinegraph.Maintenance.RepairImdbIds do
  @moduledoc """
  Release-safe maintenance entry point for the IMDb-id repair backfill.
  Enqueues one `TMDbDetailsWorker` job per movie where `imdb_id IS NULL`
  but `tmdb_id IS NOT NULL` — TMDb returns the IMDb id on most fetches.

  Reachable from:
  - `mix cinegraph.movies.repair_imdb_ids` (dev)
  - `Cinegraph.Workers.ImdbIdRepairSweeper` (Oban Cron, prod)
  - `bin/cinegraph eval "Cinegraph.Maintenance.RepairImdbIds.run([])"` (one-shot)

  Canonical-list movies are prioritised first.

  See #745 Phase 1.2.

  ## Options
    * `:limit` (positive integer)
    * `:dry_run` (boolean)

  ## Returns
  `{:ok, %{found, enqueued, failed, dry_run}}`
  """

  alias Cinegraph.Repo
  alias Cinegraph.Workers.TMDbDetailsWorker

  import Ecto.Query
  require Logger

  @insert_chunk_size 500

  @spec run(keyword()) ::
          {:ok,
           %{
             found: non_neg_integer(),
             enqueued: non_neg_integer(),
             failed: non_neg_integer(),
             dry_run: boolean()
           }}
  def run(opts \\ []) when is_list(opts) do
    base =
      from m in "movies",
        where: (is_nil(m.imdb_id) or m.imdb_id == "") and not is_nil(m.tmdb_id),
        order_by: [
          desc: fragment("? != '{}'::jsonb", m.canonical_sources),
          desc: m.id
        ],
        select: m.tmdb_id

    capped =
      case Keyword.get(opts, :limit) do
        nil ->
          base

        n when is_integer(n) and n > 0 ->
          from(q in base, limit: ^n)

        other ->
          raise ArgumentError,
                ":limit must be a positive integer or nil, got: #{inspect(other)}"
      end

    tmdb_ids = Repo.replica().all(capped)
    found = length(tmdb_ids)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Logger.info("RepairImdbIds: dry-run found #{found} movies to repair")
      {:ok, %{found: found, enqueued: 0, failed: 0, dry_run: true}}
    else
      {enqueued, failed} = enqueue_in_chunks(tmdb_ids)
      Logger.info("RepairImdbIds: enqueued #{enqueued} jobs on :tmdb (#{failed} failed)")
      {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false}}
    end
  end

  defp enqueue_in_chunks(tmdb_ids) do
    tmdb_ids
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      jobs = Enum.map(chunk, &TMDbDetailsWorker.new(%{"tmdb_id" => &1}))

      try do
        case Oban.insert_all(jobs) do
          results when is_list(results) ->
            {ok + length(results), err}

          other ->
            Logger.error("Oban.insert_all returned unexpected value: #{inspect(other)}")
            {ok, err + length(chunk)}
        end
      rescue
        e ->
          Logger.error(
            "Oban.insert_all failed for chunk of #{length(chunk)}: #{Exception.message(e)}"
          )

          {ok, err + length(chunk)}
      end
    end)
  end
end
