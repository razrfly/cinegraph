defmodule Cinegraph.Workers.CanonicalRetryWorker do
  @moduledoc """
  Worker to retry adding canonical sources to movies that failed during initial import.
  """

  use Oban.Worker,
    queue: :scraping,
    max_attempts: 3,
    unique: [
      fields: [:args],
      keys: [:movie_id, :source_key],
      # 1 hour
      period: 3600
    ]

  alias Cinegraph.{Repo, Movies}
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "movie_id" => movie_id,
          "source_key" => source_key,
          "canonical_data" => canonical_data
        }
      }) do
    Logger.info("Retrying canonical source addition for movie #{movie_id}, source: #{source_key}")

    case Repo.get(Movies.Movie, movie_id) do
      nil ->
        Logger.error("Movie #{movie_id} not found")
        {:error, :movie_not_found}

      movie ->
        current_sources = movie.canonical_sources || %{}

        if Map.has_key?(current_sources, source_key) do
          Logger.info("Movie #{movie.title} already has canonical source #{source_key}")
          :ok
        else
          updated_sources = Map.put(current_sources, source_key, canonical_data)

          case movie
               |> Movies.Movie.changeset(%{canonical_sources: updated_sources})
               |> Repo.update() do
            {:ok, updated_movie} ->
              Logger.info("Successfully added #{source_key} to #{movie.title}")

              # Verify the update
              final_sources = updated_movie.canonical_sources || %{}

              if Map.has_key?(final_sources, source_key) do
                Logger.info("Verified: #{source_key} is now in canonical_sources")
                :ok
              else
                Logger.error("ERROR: #{source_key} was NOT added to canonical_sources!")
                {:error, :update_not_persisted}
              end

            {:error, changeset} ->
              Logger.error("Failed to update movie: #{inspect(changeset.errors)}")
              {:error, changeset}
          end
        end
    end
  end

  @doc """
  Queue a retry for adding a canonical source to a movie.
  """
  def queue_retry(movie_id, source_key, canonical_data) do
    %{
      movie_id: movie_id,
      source_key: source_key,
      canonical_data: canonical_data
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end
end
