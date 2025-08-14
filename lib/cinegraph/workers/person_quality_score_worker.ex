defmodule Cinegraph.Workers.PersonQualityScoreWorker do
  @moduledoc """
  Oban worker for calculating Person Quality Scores periodically.
  
  Can be run for a single person or all people.
  """
  
  use Oban.Worker,
    queue: :metrics,
    max_attempts: 3,
    unique: [period: 3600]  # Prevent duplicate jobs within 1 hour

  alias Cinegraph.Metrics.PersonQualityScore
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"person_id" => person_id}}) do
    Logger.info("Calculating PQS for person #{person_id}")
    
    case PersonQualityScore.calculate_director_score(person_id) do
      {:ok, score} ->
        case PersonQualityScore.store_person_score(person_id, score) do
          {:ok, _metric} ->
            Logger.info("PQS calculated and stored for person #{person_id}: #{score}")
            :ok
          {:error, reason} ->
            Logger.error("Failed to store PQS for person #{person_id}: #{inspect(reason)}")
            {:error, reason}
        end
      {:error, reason} ->
        Logger.error("Failed to calculate PQS for person #{person_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch" => "all_directors"}}) do
    Logger.info("Starting batch PQS calculation for all directors")
    
    case PersonQualityScore.calculate_all_director_scores() do
      {:ok, %{total: total, successful: successful}} ->
        Logger.info("PQS batch complete: #{successful}/#{total} directors processed")
        :ok
      {:error, reason} ->
        Logger.error("Failed to calculate batch PQS: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Schedule a job to calculate PQS for a specific person.
  """
  def schedule_person(person_id) do
    %{person_id: person_id}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Schedule a job to calculate PQS for all directors.
  """
  def schedule_all_directors do
    %{batch: "all_directors"}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Schedule recurring calculation of all director scores.
  Call this from application startup or a scheduler.
  """
  def schedule_recurring do
    # Schedule immediate calculation
    schedule_all_directors()
    
    # You could also add this to Oban's cron configuration
    # in config.exs for automatic weekly recalculation:
    # 
    # config :cinegraph, Oban,
    #   crontab: [
    #     {"0 0 * * SUN", Cinegraph.Workers.PersonQualityScoreWorker, args: %{batch: "all_directors"}}
    #   ]
  end
end