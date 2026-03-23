defmodule Cinegraph.Workers.PredictionCalculator do
  @moduledoc """
  Oban worker for calculating movie predictions and storing them in cache.
  Uses the existing MoviePredictor logic to ensure correct scoring.
  """

  use Oban.Worker, queue: :metrics, max_attempts: 3

  require Logger

  alias Cinegraph.Repo
  alias Cinegraph.Predictions.{MoviePredictor, PredictionCache}
  alias Cinegraph.Metrics.MetricWeightProfile

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"decade" => decade, "profile_id" => profile_id}}) do
    Logger.info("Starting prediction calculation for decade #{decade}, profile #{profile_id}")

    profile = Repo.get!(MetricWeightProfile, profile_id)

    # Use the EXISTING MoviePredictor logic that actually works
    predictions_result = MoviePredictor.predict_2020s_movies(1000, profile)

    # Transform predictions to cache format
    movie_scores =
      Enum.reduce(predictions_result.predictions, %{}, fn pred, acc ->
        Map.put(acc, to_string(pred.id), %{
          "title" => pred.title,
          # Already 0-100
          "score" => pred.prediction.likelihood_percentage,
          "release_date" => Date.to_iso8601(pred.release_date),
          "year" => pred.year,
          "status" => Atom.to_string(pred.status),
          "canonical_sources" => pred.movie.canonical_sources || %{},
          "total_score" => pred.prediction.total_score,
          "breakdown" => format_breakdown(pred.prediction.breakdown)
        })
      end)

    # Calculate statistics
    statistics = calculate_statistics(predictions_result.predictions)

    # Store in cache
    {:ok, _cache} =
      PredictionCache.upsert_cache(%{
        decade: decade,
        profile_id: profile_id,
        movie_scores: movie_scores,
        statistics: statistics,
        calculated_at: DateTime.utc_now(),
        metadata: %{
          "algorithm_info" => predictions_result.algorithm_info,
          "total_candidates" => predictions_result.total_candidates,
          "calculation_timestamp" => DateTime.utc_now()
        }
      })

    Logger.info("Successfully cached #{map_size(movie_scores)} predictions for decade #{decade}")

    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  # Private helpers

  defp calculate_statistics(predictions) do
    scores = Enum.map(predictions, & &1.prediction.likelihood_percentage)

    %{
      "total_predictions" => length(predictions),
      "average_score" => calculate_average(scores),
      "median_score" => calculate_median(scores),
      "high_confidence_count" => Enum.count(scores, &(&1 >= 80)),
      "medium_confidence_count" => Enum.count(scores, &(&1 >= 50 and &1 < 80)),
      "low_confidence_count" => Enum.count(scores, &(&1 < 50)),
      "already_added_count" => Enum.count(predictions, &(&1.status == :already_added)),
      "future_prediction_count" => Enum.count(predictions, &(&1.status == :future_prediction))
    }
  end

  defp calculate_average([]), do: 0

  defp calculate_average(scores) do
    Float.round(Enum.sum(scores) / length(scores), 2)
  end

  defp calculate_median([]), do: 0

  defp calculate_median(scores) do
    sorted = Enum.sort(scores)
    mid = div(length(sorted), 2)

    if rem(length(sorted), 2) == 0 do
      Float.round((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2, 2)
    else
      Float.round(Enum.at(sorted, mid), 2)
    end
  end

  defp format_breakdown(breakdown) when is_list(breakdown) do
    Enum.map(breakdown, fn item ->
      %{
        "criterion" => Atom.to_string(item.criterion),
        "raw_score" => item.raw_score,
        "weight" => item.weight,
        "weighted_points" => item.weighted_points
      }
    end)
  end

  defp format_breakdown(_), do: []
end
