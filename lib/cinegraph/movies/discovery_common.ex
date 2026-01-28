defmodule Cinegraph.Movies.DiscoveryCommon do
  @moduledoc """
  Shared logic for discovery scoring modules.
  Contains presets and normalization functions used by both
  DiscoveryScoring and DiscoveryScoringSimple modules.

  ## Discovery Score Configuration

  The discovery score combines recency (how new a film is) with relevance
  (how much people care about it). All weights are configurable here.

  ### Recency Settings
  - `@recency_decay_rate` - Controls how fast old films fade (lower = slower decay)
  - Half-life is approximately 0.693 / decay_rate days

  ### Weight Distribution
  Weights should sum to 1.0. Adjust to change what matters most:
  - Higher `recency` = favor newer films
  - Higher `popular_opinion` = favor well-rated films
  - Higher `cultural_impact` = favor popular/canonical films
  """

  # =============================================================================
  # DISCOVERY SCORE SETTINGS (edit these to tune the algorithm)
  # =============================================================================

  # How fast recency score decays (lower = slower decay)
  # At 0.01: 30 days = 0.74, 90 days = 0.41, 365 days = 0.03
  @recency_decay_rate 0.01

  # Weights for discovery score (must sum to 1.0)
  @discovery_weights %{
    recency: 0.35,
    popularity: 0.35,
    votes: 0.20,
    rating: 0.10
  }

  # Minimum votes required to include rating in score (prevents low-sample bias)
  @min_votes_for_rating 10

  # =============================================================================
  # LEGACY WEIGHTS (for existing discovery scoring system)
  # =============================================================================

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

  # =============================================================================
  # DISCOVERY SCORE ACCESSORS
  # =============================================================================

  @doc """
  Returns the recency decay rate.
  Lower values = slower decay (older films stay relevant longer).
  """
  def recency_decay_rate, do: @recency_decay_rate

  @doc """
  Returns the discovery score weights.
  Keys: :recency, :popularity, :votes, :rating
  """
  def discovery_weights, do: @discovery_weights

  @doc """
  Returns the minimum votes required to include rating in discovery score.
  """
  def min_votes_for_rating, do: @min_votes_for_rating

  @doc """
  Returns the approximate half-life in days for the recency score.
  After this many days, a film's recency score drops to ~0.5.
  """
  def recency_half_life_days, do: round(0.693 / @recency_decay_rate)
end
