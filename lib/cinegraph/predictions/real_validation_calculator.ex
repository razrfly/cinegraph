defmodule Cinegraph.Predictions.RealValidationCalculator do
  @moduledoc """
  Calculates REAL validation accuracy by comparing predictions against
  actual movies that made it to the 1001 Movies list.
  """
  
  alias Cinegraph.Repo
  alias Cinegraph.Predictions.PredictionCache
  import Ecto.Query
  
  @doc """
  Calculate real validation accuracy for a profile and decade.
  Returns accuracy percentage based on how many of the top predictions
  actually made it to the 1001 Movies list.
  """
  def calculate_accuracy(profile_id, decade, top_n \\ 50) do
    case get_cache_record(profile_id, decade) do
      nil -> 
        {:error, "No cache record found"}
      
      cache_record ->
        calculate_from_cache(cache_record, top_n)
    end
  end
  
  defp get_cache_record(profile_id, decade) do
    Repo.one(
      from pc in PredictionCache,
        where: pc.profile_id == ^profile_id and pc.decade == ^decade,
        limit: 1
    )
  end
  
  defp calculate_from_cache(cache_record, top_n) do
    # Get top N predictions sorted by score
    top_predictions = 
      cache_record.movie_scores
      |> Enum.map(fn {movie_id, data} ->
        {movie_id, Map.get(data, "score", 0)}
      end)
      |> Enum.sort_by(fn {_id, score} -> score end, :desc)
      |> Enum.take(top_n)
    
    # Count how many are already in 1001 Movies
    correct_predictions = 
      top_predictions
      |> Enum.count(fn {movie_id, _score} ->
        movie_data = Map.get(cache_record.movie_scores, movie_id, %{})
        status = Map.get(movie_data, "status")
        canonical_sources = Map.get(movie_data, "canonical_sources", %{})
        
        # Check if it's already added OR has 1001_movies in canonical sources
        status == "already_added" || 
        Map.has_key?(canonical_sources, "1001_movies")
      end)
    
    accuracy_percentage = if top_n > 0 do
      Float.round(correct_predictions / top_n * 100, 1)
    else
      0.0
    end
    
    {:ok, %{
      accuracy_percentage: accuracy_percentage,
      correct_predictions: correct_predictions,
      total_predictions: top_n,
      decade: cache_record.decade
    }}
  end
  
  @doc """
  Calculate accuracy for all decades of a profile.
  """
  def calculate_all_decades(profile_id, top_n \\ 50) do
    cache_records = 
      Repo.all(
        from pc in PredictionCache,
          where: pc.profile_id == ^profile_id,
          order_by: [asc: pc.decade]
      )
    
    decade_results = 
      Enum.map(cache_records, fn record ->
        case calculate_from_cache(record, top_n) do
          {:ok, result} -> result
          _ -> nil
        end
      end)
      |> Enum.filter(&(&1 != nil))
    
    # Calculate overall accuracy
    total_correct = Enum.sum(Enum.map(decade_results, & &1.correct_predictions))
    total_predictions = Enum.sum(Enum.map(decade_results, & &1.total_predictions))
    
    overall_accuracy = if total_predictions > 0 do
      Float.round(total_correct / total_predictions * 100, 1)
    else
      0.0
    end
    
    %{
      overall_accuracy: overall_accuracy,
      decade_results: decade_results,
      total_correct: total_correct,
      total_predictions: total_predictions
    }
  end
end