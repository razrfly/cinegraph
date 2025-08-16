defmodule Cinegraph.Workers.PersonQualityScoreWorker do
  @moduledoc """
  Oban worker for calculating Person Quality Scores using universal algorithm.

  Works for all roles: directors, actors, writers, producers, etc.
  Can be run for a single person or all people with significant credits.
  """

  use Oban.Worker,
    queue: :metrics,
    max_attempts: 3,
    # Prevent duplicate jobs within 1 hour
    unique: [period: 3600]

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
    Logger.info(
      "Starting batch universal PQS calculation for all people with min #{min_credits} credits"
    )

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

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"batch" => "daily_incremental", "person_ids" => person_ids, "trigger" => trigger}
      }) do
    Logger.info(
      "Starting daily incremental PQS calculation (trigger: #{trigger}, #{length(person_ids)} people)"
    )

    results =
      Enum.map(person_ids, fn person_id ->
        case PersonQualityScore.calculate_person_score(person_id) do
          {:ok, score, components} ->
            case PersonQualityScore.store_person_score(person_id, score, components) do
              {:ok, _} -> {:ok, person_id, score}
              error -> {:error, person_id, error}
            end

          {:error, error} ->
            {:error, person_id, error}
        end
      end)

    successful = Enum.count(results, fn {status, _, _} -> status == :ok end)

    Logger.info(
      "Daily incremental PQS complete: #{successful}/#{length(person_ids)} people processed"
    )

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"batch" => "weekly_full", "trigger" => trigger, "min_credits" => min_credits}
      }) do
    Logger.info(
      "Starting weekly full PQS calculation (trigger: #{trigger}, min_credits: #{min_credits})"
    )

    case PersonQualityScore.calculate_all_person_scores(min_credits) do
      {:ok, %{total: total, successful: successful}} ->
        Logger.info("Weekly full PQS complete: #{successful}/#{total} people processed")
        :ok

      {:error, reason} ->
        Logger.error("Weekly full PQS failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"batch" => "monthly_deep", "trigger" => trigger, "min_credits" => min_credits}
      }) do
    Logger.info(
      "Starting monthly deep PQS calculation (trigger: #{trigger}, min_credits: #{min_credits})"
    )

    case PersonQualityScore.calculate_all_person_scores(min_credits) do
      {:ok, %{total: total, successful: successful}} ->
        Logger.info("Monthly deep PQS complete: #{successful}/#{total} people processed")
        :ok

      {:error, reason} ->
        Logger.error("Monthly deep PQS failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Health check removed - handled by PQSScheduler.check_system_health/0 via cron
  # to avoid duplicate triggers of emergency recalculations

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "batch" => "stale_cleanup",
          "person_ids" => person_ids,
          "trigger" => trigger,
          "max_age_days" => max_age_days
        }
      }) do
    Logger.info(
      "Starting PQS stale cleanup (trigger: #{trigger}, max_age: #{max_age_days} days, #{length(person_ids)} people)"
    )

    results =
      Enum.map(person_ids, fn person_id ->
        case PersonQualityScore.calculate_person_score(person_id) do
          {:ok, score, components} ->
            case PersonQualityScore.store_person_score(person_id, score, components) do
              {:ok, _} -> {:ok, person_id, score}
              error -> {:error, person_id, error}
            end

          {:error, error} ->
            {:error, person_id, error}
        end
      end)

    successful = Enum.count(results, fn {status, _, _} -> status == :ok end)

    Logger.info(
      "Stale cleanup PQS complete: #{successful}/#{length(person_ids)} people processed"
    )

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"batch" => "credit_changes", "person_ids" => person_ids, "trigger" => trigger}
      }) do
    Logger.info(
      "Starting PQS batch for credit changes (trigger: #{trigger}, #{length(person_ids)} people)"
    )

    results =
      Enum.map(person_ids, fn person_id ->
        case PersonQualityScore.calculate_person_score(person_id) do
          {:ok, score, components} ->
            case PersonQualityScore.store_person_score(person_id, score, components) do
              {:ok, _} -> {:ok, person_id, score}
              error -> {:error, person_id, error}
            end

          {:error, error} ->
            {:error, person_id, error}
        end
      end)

    successful = Enum.count(results, fn {status, _, _} -> status == :ok end)

    Logger.info(
      "Credit changes PQS batch complete: #{successful}/#{length(person_ids)} people processed"
    )

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "batch" => "festival_import",
          "person_ids" => person_ids,
          "ceremony_id" => ceremony_id,
          "trigger" => trigger
        }
      }) do
    Logger.info(
      "Starting PQS batch for festival import (trigger: #{trigger}, ceremony: #{ceremony_id}, #{length(person_ids)} people)"
    )

    results =
      Enum.map(person_ids, fn person_id ->
        case PersonQualityScore.calculate_person_score(person_id) do
          {:ok, score, components} ->
            case PersonQualityScore.store_person_score(person_id, score, components) do
              {:ok, _} -> {:ok, person_id, score}
              error -> {:error, person_id, error}
            end

          {:error, error} ->
            {:error, person_id, error}
        end
      end)

    successful = Enum.count(results, fn {status, _, _} -> status == :ok end)

    Logger.info(
      "Festival import PQS batch complete: #{successful}/#{length(person_ids)} people processed"
    )

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "batch" => "external_metrics",
          "person_ids" => person_ids,
          "movie_ids" => movie_ids,
          "trigger" => trigger
        }
      }) do
    Logger.info(
      "Starting PQS batch for external metrics (trigger: #{trigger}, #{length(movie_ids)} movies, #{length(person_ids)} people)"
    )

    results =
      Enum.map(person_ids, fn person_id ->
        case PersonQualityScore.calculate_person_score(person_id) do
          {:ok, score, components} ->
            case PersonQualityScore.store_person_score(person_id, score, components) do
              {:ok, _} -> {:ok, person_id, score}
              error -> {:error, person_id, error}
            end

          {:error, error} ->
            {:error, person_id, error}
        end
      end)

    successful = Enum.count(results, fn {status, _, _} -> status == :ok end)

    Logger.info(
      "External metrics PQS batch complete: #{successful}/#{length(person_ids)} people processed"
    )

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "batch" => "emergency_recalculation",
          "trigger" => trigger,
          "reason" => reason,
          "min_credits" => min_credits
        }
      }) do
    Logger.warning(
      "Starting emergency PQS recalculation (trigger: #{trigger}, reason: #{reason})"
    )

    case PersonQualityScore.calculate_all_person_scores(min_credits) do
      {:ok, %{total: total, successful: successful}} ->
        Logger.info(
          "Emergency PQS recalculation complete: #{successful}/#{total} people processed"
        )

        :ok

      {:error, reason} ->
        Logger.error("Emergency PQS recalculation failed: #{inspect(reason)}")
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
