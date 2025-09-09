defmodule Cinegraph.Movies.DiscoveryCommon do
  @moduledoc """
  Shared logic for discovery scoring modules.
  Contains presets and normalization functions used by both
  DiscoveryScoring and DiscoveryScoringSimple modules.
  """

  @default_weights %{
    # Combined all rating sources
    popular_opinion: 0.25,
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
        # Focus on popular ratings
        popular_opinion: 0.5,
        industry_recognition: 0.1,
        cultural_impact: 0.2,
        people_quality: 0.2
      },
      critics_choice: %{
        # All ratings, but Metacritic/RT weighted higher in implementation
        popular_opinion: 0.5,
        industry_recognition: 0.2,
        cultural_impact: 0.1,
        people_quality: 0.2
      },
      award_winner: %{
        # Some consideration of ratings
        popular_opinion: 0.25,
        industry_recognition: 0.5,
        cultural_impact: 0.1,
        people_quality: 0.15
      },
      cult_classic: %{
        # Moderate ratings consideration
        popular_opinion: 0.25,
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
