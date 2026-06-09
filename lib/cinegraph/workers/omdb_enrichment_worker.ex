defmodule Cinegraph.Workers.OMDbEnrichmentWorker do
  @moduledoc """
  Oban worker for enriching movie data with OMDb API information.

  This worker fetches additional movie data from OMDb including awards,
  box office information, and critic ratings.
  """

  use Oban.Worker,
    queue: :omdb,
    max_attempts: 3,
    # 1 hour uniqueness
    unique: [fields: [:args], keys: [:movie_id], period: 3600]

  alias Cinegraph.Metrics
  alias Cinegraph.ApiProcessors.OMDb
  alias Cinegraph.Freshness
  require Logger

  @impl Oban.Worker
  # #923: do NOT add an outer "already has omdb_data?" guard here — the schema
  # marks omdb_data load_in_query: false, so any naive `Movies.get_movie!/1`
  # would silently see nil and call the OMDb API for every job, burning quota.
  # OMDb.process_movie/2 owns the skip decision: it selects omdb_data
  # explicitly AND verifies a matching external_metrics row exists.
  def perform(%Oban.Job{args: %{"movie_id" => movie_id} = args}) do
    # Route all Repo.replica() calls through the dedicated worker pool
    # so this job does not compete with web requests for Repo.Replica connections. (#1007)
    Cinegraph.Repo.route_to_worker()
    Logger.info("OMDb Enrichment Worker processing movie #{movie_id}")
    force = Map.get(args, "force", false)
    process_omdb_data(movie_id, force)
  end

  defp process_omdb_data(movie_id, force) do
    case OMDb.process_movie(movie_id, force_refresh: force) do
      {:ok, updated_movie} ->
        Logger.info("Successfully enriched movie #{movie_id} with OMDb data")
        # #1096 Phase B: record freshness uniformly (additive — values still in omdb_data).
        Freshness.touch("movie", updated_movie.id, "omdb", :ok,
          base_date: updated_movie.release_date
        )

        {:ok, updated_movie}

      {:error, :movie_not_found} ->
        Logger.error("Movie #{movie_id} not found")
        {:error, :movie_not_found}

      {:error, :invalid_imdb_id} ->
        Logger.info("Invalid IMDb ID for movie #{movie_id}, skipping")
        # No usable IMDb ID → OMDb can never resolve it (precondition-ineligible, #1010 §6).
        Freshness.touch("movie", movie_id, "omdb", :ineligible)
        :ok

      {:error, :rate_limited} ->
        # OMDb has strict rate limits (1000/day for free tier)
        # Reschedule for later
        Logger.warning("OMDb rate limited, rescheduling movie #{movie_id}")
        # Retry in 1 hour
        {:snooze, 3600}

      {:error, reason}
      when reason in ["Error getting data.", "Incorrect IMDb ID.", "Movie not found!"] ->
        Logger.info("OMDb unavailable for movie #{movie_id} (#{reason}), recording fetch attempt")
        record_fetch_attempt(movie_id, reason)
        # Source had nothing → :empty (the empty-multiplier TTL subsumes the 90-day cooldown).
        Freshness.touch("movie", movie_id, "omdb", :empty, error_reason: reason)
        :ok

      {:error, %Jason.DecodeError{}} ->
        Logger.warning(
          "OMDb returned malformed JSON for movie #{movie_id}, recording fetch attempt"
        )

        record_fetch_attempt(movie_id, "malformed_response")
        Freshness.touch("movie", movie_id, "omdb", :empty, error_reason: "malformed_response")
        :ok

      {:error, reason} ->
        Logger.error("Failed to enrich movie #{movie_id} with OMDb: #{inspect(reason)}")
        Freshness.touch("movie", movie_id, "omdb", :error, error_reason: inspect(reason))
        {:error, reason}
    end
  end

  defp record_fetch_attempt(movie_id, reason) do
    case Metrics.upsert_metric(%{
           movie_id: movie_id,
           source: "omdb",
           metric_type: "fetch_attempt",
           text_value: reason,
           fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "Failed to record fetch_attempt for movie #{movie_id} " <>
            "(reason=#{reason}): #{inspect(changeset)}"
        )

        :ok
    end
  end
end
