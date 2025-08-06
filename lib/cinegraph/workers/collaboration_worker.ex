defmodule Cinegraph.Workers.CollaborationWorker do
  @moduledoc """
  Oban worker for processing movie collaborations.

  This worker updates the collaboration data after new movies are imported.
  """

  use Oban.Worker,
    queue: :collaboration,
    max_attempts: 3,
    # Unique per movie_id for 60 seconds
    unique: [period: 60, fields: [:args]]

  alias Cinegraph.Collaborations
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"movie_id" => movie_id}}) do
    Logger.info("Processing collaborations for movie #{movie_id}")

    case Collaborations.populate_movie_collaborations(movie_id) do
      {:ok, count} ->
        Logger.info("Successfully processed #{count} collaborations for movie #{movie_id}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to process collaborations for movie #{movie_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Legacy handler for jobs without movie_id
  def perform(%Oban.Job{args: _args}) do
    Logger.info("Skipping legacy collaboration job without movie_id")
    :ok
  end
end
