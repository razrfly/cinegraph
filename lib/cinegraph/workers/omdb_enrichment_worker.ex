defmodule Cinegraph.Workers.OMDbEnrichmentWorker do
  @moduledoc """
  Oban worker for enriching movie data with OMDb API information.

  This worker fetches additional movie data from OMDb including awards,
  box office information, and critic ratings.
  """

  use Oban.Worker,
    queue: :omdb_enrichment,
    max_attempts: 3,
    # 1 hour uniqueness
    unique: [fields: [:args], keys: [:movie_id], period: 3600]

  alias Cinegraph.Movies
  alias Cinegraph.ApiProcessors.OMDb
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"movie_id" => movie_id} = args}) do
    Logger.info("OMDb Enrichment Worker processing movie #{movie_id}")

    try do
      movie = Movies.get_movie!(movie_id)

      if movie.omdb_data do
        Logger.info("Movie #{movie_id} already has OMDb data, skipping")
        :ok
      else
        process_omdb_data(movie, args)
      end
    rescue
      Ecto.NoResultsError ->
        Logger.error("Movie #{movie_id} not found")
        {:error, :movie_not_found}
    end
  end

  defp process_omdb_data(movie, _args) do
    case OMDb.process_movie(movie.id) do
      {:ok, updated_movie} ->
        Logger.info("Successfully enriched movie #{movie.id} with OMDb data")
        {:ok, updated_movie}

      {:error, :rate_limited} ->
        # OMDb has strict rate limits (1000/day for free tier)
        # Reschedule for later
        Logger.warning("OMDb rate limited, rescheduling movie #{movie.id}")
        # Retry in 1 hour
        {:snooze, 3600}

      {:error, reason} ->
        Logger.error("Failed to enrich movie #{movie.id} with OMDb: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
