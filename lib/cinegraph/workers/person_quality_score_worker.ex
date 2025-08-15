defmodule Cinegraph.Workers.PersonQualityScoreWorker do
  @moduledoc """
  Oban worker for calculating Person Quality Scores using universal algorithm.
  
  Works for all roles: directors, actors, writers, producers, etc.
  Can be run for a single person or all people with significant credits.
  """
  
  use Oban.Worker,
    queue: :metrics,
    max_attempts: 3,
    unique: [period: 3600]  # Prevent duplicate jobs within 1 hour

  alias Cinegraph.Metrics.PersonQualityScore
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"person_id" => person_id}}) do
    Logger.info("Calculating universal PQS for person #{person_id}")
    
    case PersonQualityScore.calculate_person_score(person_id) do
      {:ok, score, components} ->
        case PersonQualityScore.store_person_score(person_id, score, components) do
          {:ok, _metric} ->
            Logger.info("Universal PQS calculated and stored for person #{person_id}: #{score}")
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
  def perform(%Oban.Job{args: %{"batch" => "all_people", "min_credits" => min_credits}}) do
    Logger.info("Starting batch universal PQS calculation for all people with min #{min_credits} credits")
    
    case PersonQualityScore.calculate_all_person_scores(min_credits) do
      {:ok, %{total: total, successful: successful}} ->
        Logger.info("Universal PQS batch complete: #{successful}/#{total} people processed")
        :ok
      {:error, reason} ->
        Logger.error("Failed to calculate batch PQS: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker  
  def perform(%Oban.Job{args: %{"batch" => "all_directors"}}) do
    # Legacy support - redirect to universal algorithm
    Logger.info("Legacy call: redirecting to universal PQS calculation")
    perform(%Oban.Job{args: %{"batch" => "all_people", "min_credits" => 5}})
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
  Schedule a job to calculate PQS for all people with significant credits.
  """
  def schedule_all_people(min_credits \\ 5) do
    %{batch: "all_people", min_credits: min_credits}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Legacy function for backward compatibility.
  """
  def schedule_all_directors do
    schedule_all_people(5)
  end

  @doc """
  Schedule recurring calculation of all person scores.
  Call this from application startup or a scheduler.
  """
  def schedule_recurring(min_credits \\ 5) do
    # Schedule immediate calculation
    schedule_all_people(min_credits)
    
    # You could also add this to Oban's cron configuration
    # in config.exs for automatic weekly recalculation:
    # 
    # config :cinegraph, Oban,
    #   crontab: [
    #     {"0 0 * * SUN", Cinegraph.Workers.PersonQualityScoreWorker, args: %{batch: "all_people", min_credits: 5}}
    #   ]
  end
end