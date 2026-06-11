defmodule Cinegraph.Freshness.ReadThrough do
  @moduledoc """
  Demand-driven (read-through) refresh (#1108 §10b / #1010 Tier 1).

  When a movie/person page is viewed, `refresh_if_stale/1` checks the freshness
  ledger and, for each stale source the `SpendGuard` allows, enqueues the
  already-proven refresh worker so the page self-freshens over time:

    * movie — any of `tmdb_details|watch_providers|imdb_id` stale → one
      `TMDbMovieRefreshWorker` (it re-hydrates all three in one call); `omdb`
      stale → one `OMDbEnrichmentWorker`. (≤2/view.)
    * person — `tmdb_person` stale → one `PersonTmdbRefreshWorker`.

  All workers are uniqueness-keyed (1h), so navigation churn collapses to one
  real job per entity per hour. `last_checked_at` is stamped on the entity's
  existing ledger rows on every evaluation (even when skipped) — the
  "viewed-but-stale" canary the dashboard reads. Off entirely unless
  `SpendGuard.enabled?`.
  """

  import Ecto.Query

  alias Cinegraph.Freshness
  alias Cinegraph.Freshness.{DataRefresh, SpendGuard}
  alias Cinegraph.Repo
  alias Cinegraph.Workers.{OMDbEnrichmentWorker, PersonTmdbRefreshWorker, TMDbMovieRefreshWorker}

  require Logger

  @movie_tmdb_sources ~w(tmdb_details watch_providers imdb_id)

  @type entity :: %{type: :movie | :person, id: integer()}
  @type result :: {:enqueued, [atom()]} | :fresh | :skipped

  @spec refresh_if_stale(entity()) :: result()
  def refresh_if_stale(entity)

  def refresh_if_stale(%{type: :movie, id: id}) do
    stale = Freshness.stale_sources(:movie, id)
    stamp_checked(:movie, id)

    []
    |> enqueue_if(tmdb_movie_stale?(stale) and SpendGuard.allow?(:tmdb_details), fn ->
      {TMDbMovieRefreshWorker.new(%{"movie_id" => id}, unique: movie_unique()), :tmdb_movie}
    end)
    |> enqueue_if("omdb" in stale and SpendGuard.allow?(:omdb), fn ->
      {OMDbEnrichmentWorker.new(%{"movie_id" => id}, unique: movie_unique()), :omdb}
    end)
    |> result(stale)
  end

  def refresh_if_stale(%{type: :person, id: id}) do
    stale = Freshness.stale_sources(:person, id)
    stamp_checked(:person, id)

    []
    |> enqueue_if("tmdb_person" in stale and SpendGuard.allow?(:tmdb_person), fn ->
      {PersonTmdbRefreshWorker.new(%{"person_id" => id}, unique: person_unique()), :tmdb_person}
    end)
    |> result(stale)
  end

  def refresh_if_stale(_), do: :skipped

  # Scope uniqueness per-worker (the workers' own `unique` is args-only, so a
  # movie's TMDb + OMDb jobs would otherwise dedup against each other). Still
  # collapses repeated same-worker enqueues within the hour.
  defp movie_unique, do: [fields: [:worker, :args], keys: [:movie_id], period: 3600]
  defp person_unique, do: [fields: [:worker, :args], keys: [:person_id], period: 3600]

  defp tmdb_movie_stale?(stale), do: Enum.any?(@movie_tmdb_sources, &(&1 in stale))

  defp enqueue_if(acc, false, _fun), do: acc

  defp enqueue_if(acc, true, fun) do
    {changeset, tag} = fun.()

    case Oban.insert(changeset) do
      {:ok, _job} ->
        acc ++ [tag]

      {:error, reason} ->
        Logger.warning("ReadThrough: enqueue #{tag} failed: #{inspect(reason)}")
        acc
    end
  end

  defp result([], []), do: :fresh
  defp result([], _stale), do: :skipped
  defp result(enqueued, _stale), do: {:enqueued, enqueued}

  # Stamp last_checked_at on the entity's EXISTING ledger rows only — never insert
  # (an inserted pending/empty row would corrupt stale? + explode the ledger).
  defp stamp_checked(entity_type, entity_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    et = to_string(entity_type)

    from(r in DataRefresh, where: r.entity_type == ^et and r.entity_id == ^entity_id)
    |> Repo.update_all(set: [last_checked_at: now])
  end
end
