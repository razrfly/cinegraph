defmodule Cinegraph.Metrics.PQSTriggerStrategy do
  @moduledoc """
  Handles event-based triggers for Person Quality Score (PQS) calculations.

  Implements the trigger strategies defined in issue #292:
  - New Person Creation (5-minute delay)
  - Credit Changes (batch every 30 minutes) 
  - Festival/Award Data Import (batch completion)
  - External Metrics Update (batch every 2 hours)
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Workers.PersonQualityScoreWorker
  require Logger

  @doc """
  Trigger PQS calculation for a newly created person.
  Schedules job with 5-minute delay to allow related data to settle.
  """
  def trigger_new_person(person_id) do
    Logger.info("Scheduling PQS calculation for new person #{person_id} (5-minute delay)")

    %{person_id: person_id, trigger: "new_person"}
    # 5 minutes
    |> PersonQualityScoreWorker.new(schedule_in: 300)
    |> Oban.insert()
  end

  @doc """
  Trigger PQS recalculation for people with credit changes.
  Only affects people with >= 3 credits to avoid noise from minor contributors.
  """
  def trigger_credit_changes(person_ids) when is_list(person_ids) do
    # Filter to people with significant credits
    eligible_people = get_people_with_min_credits(person_ids, 3)

    if length(eligible_people) > 0 do
      Logger.info(
        "Scheduling PQS batch for #{length(eligible_people)} people with credit changes"
      )

      %{
        batch: "credit_changes",
        person_ids: eligible_people,
        trigger: "credit_changes"
      }
      |> PersonQualityScoreWorker.new()
      |> Oban.insert()
    else
      Logger.debug("No people with sufficient credits found for credit change batch")
      :ok
    end
  end

  def trigger_credit_changes(person_id) when is_integer(person_id) do
    trigger_credit_changes([person_id])
  end

  @doc """
  Trigger PQS recalculation after festival/award data import.
  Affects people with new nominations or wins.
  """
  def trigger_festival_import_completion(ceremony_id) do
    # Get people affected by this ceremony's nominations
    affected_people = get_people_with_festival_nominations(ceremony_id)

    if length(affected_people) > 0 do
      Logger.info(
        "Scheduling PQS batch for #{length(affected_people)} people after festival import (ceremony #{ceremony_id})"
      )

      %{
        batch: "festival_import",
        person_ids: affected_people,
        ceremony_id: ceremony_id,
        trigger: "festival_import"
      }
      |> PersonQualityScoreWorker.new()
      |> Oban.insert()
    else
      Logger.debug("No people found for festival import batch (ceremony #{ceremony_id})")
      :ok
    end
  end

  @doc """
  Trigger PQS recalculation for people in movies with updated external metrics.
  Batches every 2 hours to handle rating updates efficiently.
  """
  def trigger_external_metrics_update(movie_ids) when is_list(movie_ids) do
    # Get people who worked on these movies
    affected_people = get_people_in_movies(movie_ids)

    if length(affected_people) > 0 do
      Logger.info(
        "Scheduling PQS batch for #{length(affected_people)} people after external metrics update"
      )

      %{
        batch: "external_metrics",
        person_ids: affected_people,
        movie_ids: movie_ids,
        trigger: "external_metrics"
      }
      |> PersonQualityScoreWorker.new()
      |> Oban.insert()
    else
      Logger.debug("No people found for external metrics batch")
      :ok
    end
  end

  def trigger_external_metrics_update(movie_id) when is_integer(movie_id) do
    trigger_external_metrics_update([movie_id])
  end

  @doc """
  Emergency trigger for quality assurance.
  Triggers full recalculation if system health metrics indicate problems.
  """
  def trigger_quality_assurance_recalculation(reason) do
    Logger.warning("Triggering emergency PQS recalculation: #{reason}")

    %{
      batch: "emergency_recalculation",
      trigger: "quality_assurance",
      reason: reason,
      min_credits: 3
    }
    # High priority
    |> PersonQualityScoreWorker.new(priority: 3)
    |> Oban.insert()
  end

  # Private helper functions

  defp get_people_with_min_credits(person_ids, min_credits) do
    from(mc in "movie_credits",
      where: mc.person_id in ^person_ids,
      group_by: mc.person_id,
      having: count(mc.movie_id) >= ^min_credits,
      select: mc.person_id
    )
    |> Repo.all()
  end

  defp get_people_with_festival_nominations(ceremony_id) do
    # Get people directly nominated
    direct_nominations =
      from(nom in "festival_nominations",
        where: nom.ceremony_id == ^ceremony_id and not is_nil(nom.person_id),
        select: nom.person_id
      )
      |> Repo.all()

    # Get people in movies that were nominated  
    movie_based_nominations =
      from(nom in "festival_nominations",
        where: nom.ceremony_id == ^ceremony_id and not is_nil(nom.movie_id),
        join: mc in "movie_credits",
        on: mc.movie_id == nom.movie_id,
        select: mc.person_id
      )
      |> Repo.all()

    (direct_nominations ++ movie_based_nominations)
    |> Enum.uniq()
  end

  defp get_people_in_movies(movie_ids) do
    from(mc in "movie_credits",
      where: mc.movie_id in ^movie_ids,
      distinct: [mc.person_id],
      select: mc.person_id
    )
    |> Repo.all()
  end
end
