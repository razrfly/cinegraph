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
    # Route all Repo.replica() calls through the dedicated worker pool
    # so this job does not compete with web requests for Repo.Replica connections. (#1007)
    Process.put(:cinegraph_job_repo, Cinegraph.Repo.Worker)
    Logger.info("Processing collaborations for movie #{movie_id}")

    case Collaborations.rebuild_movie_collaborations(movie_id) do
      {:ok, %{details: details, affected_pairs: affected_pairs}} ->
        Logger.info(
          "Successfully rebuilt #{details} collaboration details for movie #{movie_id} across #{affected_pairs} affected pairs"
        )

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
