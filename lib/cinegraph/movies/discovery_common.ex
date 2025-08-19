defmodule Cinegraph.Movies.DiscoveryCommon do
  @moduledoc """
  Shared logic for discovery scoring modules.
  Contains presets and normalization functions used by both
  DiscoveryScoring and DiscoveryScoringSimple modules.
  """

  @default_weights %{
    popular_opinion: 0.25,    # Combined all rating sources
    industry_recognition: 0.25,
    cultural_impact: 0.25,
    people_quality: 0.25
  }

  @doc """
  Returns scoring presets for common use cases.
  """
  def get_presets do
    %{
      balanced: @default_weights,
      crowd_pleaser: %{
        popular_opinion: 0.5,     # Focus on popular ratings
        industry_recognition: 0.1,
        cultural_impact: 0.2,
        people_quality: 0.2
      },
      critics_choice: %{
        popular_opinion: 0.5,     # All ratings, but Metacritic/RT weighted higher in implementation
        industry_recognition: 0.2,
        cultural_impact: 0.1,
        people_quality: 0.2
      },
      award_winner: %{
        popular_opinion: 0.25,    # Some consideration of ratings
        industry_recognition: 0.5,
        cultural_impact: 0.1,
        people_quality: 0.15
      },
      cult_classic: %{
        popular_opinion: 0.25,    # Moderate ratings consideration
        industry_recognition: 0.1,
        cultural_impact: 0.5,
        people_quality: 0.15
      }
    }
  end

  @doc """
  Normalizes weights to sum to 1.0.

  ## Parameters
  - weights: Map of weights to normalize

  ## Returns
  Normalized weights map where all values sum to 1.0
  """
  def normalize_weights(weights) do
    weights = Map.merge(@default_weights, weights)
    total = Enum.sum(Map.values(weights))

    if total == 0 do
      @default_weights
    else
      Map.new(weights, fn {k, v} -> {k, v / total} end)
    end
  end

  @doc """
  Returns the default weights configuration.
  """
  def default_weights, do: @default_weights
end
