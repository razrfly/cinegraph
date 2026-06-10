defmodule Cinegraph.Maintenance.RefreshProfileData do
  @moduledoc """
  Release-safe maintenance entry point for the profile-data backfill — covers
  both `profile_path` and `known_for_department` for canonical-list people.
  A single TMDb `/person/:id` fetch (via `PersonTmdbRefreshWorker`) populates
  all three TMDb-derived fields (biography, profile_path, known_for_department)
  at once, so this complements `Cinegraph.Maintenance.RefreshBiographies` —
  the 1-hour unique constraint on `:person_id` collapses overlapping jobs
  when both sweepers fire within the same window.

  Reachable from:
  - `mix cinegraph.people.refresh_profile_data` (dev)
  - `Cinegraph.Workers.ProfileDataRefreshSweeper` (Oban Cron, prod)
  - `bin/cinegraph eval "Cinegraph.Maintenance.RefreshProfileData.run([])"` (one-shot)

  See #745 Phase 1.3 (profile_path) + Phase 1.6 (known_for_department).

  ## Options
    * `:limit` (positive integer)
    * `:dry_run` (boolean)

  ## Returns
  `{:ok, %{found, enqueued, failed, dry_run}}`
  """

  alias Cinegraph.Repo
  alias Cinegraph.Workers.PersonTmdbRefreshWorker

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
    # Bind Elixir UTC time (not Postgres now()) — timezone-safe staleness check
    # against the :utc_datetime column (#1101 WS1).
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base =
      from p in "people",
        join: mc in "movie_credits",
        on: mc.person_id == p.id,
        join: m in "movies",
        on: m.id == mc.movie_id,
        where:
          (is_nil(p.profile_path) or is_nil(p.known_for_department)) and
            fragment("? != '{}'::jsonb", m.canonical_sources) and
            not is_nil(p.tmdb_id) and
            fragment(
              "NOT EXISTS (SELECT 1 FROM data_refreshes dr WHERE dr.entity_type = 'person' AND dr.entity_id = ? AND dr.source = 'tmdb_person' AND (dr.status = 'ineligible' OR (dr.status IN ('ok','empty','error','pending') AND dr.stale_after > ?)))",
              p.id,
              ^now
            ),
        distinct: p.id,
        order_by: [asc: p.id],
        select: p.id

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

    ids = Repo.replica().all(capped)
    found = length(ids)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Logger.info("RefreshProfileData: dry-run found #{found} people to refresh")
      {:ok, %{found: found, enqueued: 0, failed: 0, dry_run: true}}
    else
      {enqueued, failed} = enqueue_in_chunks(ids)
      Logger.info("RefreshProfileData: enqueued #{enqueued} jobs on :tmdb (#{failed} failed)")
      {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: false}}
    end
  end

  defp enqueue_in_chunks(ids) do
    ids
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {ok, err} ->
      jobs = Enum.map(chunk, &PersonTmdbRefreshWorker.new(%{person_id: &1}))

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
