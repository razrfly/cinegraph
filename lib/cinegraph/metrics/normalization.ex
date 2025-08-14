defmodule Cinegraph.Metrics.Normalization do
  @moduledoc """
  Centralized normalization functions for movie metrics.
  Provides consistent normalization across the application.
  """

  @doc """
  Configuration for metric normalization weights.
  These can be moved to application config or database in the future.
  """
  def canonical_sources_weight, do: 0.1
  def popularity_max_value, do: 1000.0

  @doc """
  Returns SQL fragment for normalizing TMDb popularity score using logarithmic scaling.
  This provides better distribution than linear normalization.
  
  Formula: LN(value + 1) / LN(max_value + 1)
  """
  def popularity_normalization_sql do
    max = popularity_max_value()
    "LN(COALESCE(?, 0) + 1) / LN(#{max} + 1)"
  end

  @doc """
  Returns SQL fragment for calculating cultural impact score.
  Combines canonical sources presence with normalized popularity.
  """
  def cultural_impact_sql do
    canonical_weight = canonical_sources_weight()
    
    """
    COALESCE(LEAST(1.0,
      COALESCE((SELECT count(*) FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 0) * #{canonical_weight} +
      #{popularity_normalization_sql()}
    ), 0)
    """
  end

  @doc """
  Normalizes a popularity value using logarithmic scaling.
  Used for in-memory calculations.
  """
  def normalize_popularity(nil), do: 0.0
  def normalize_popularity(value) when is_number(value) do
    max = popularity_max_value()
    :math.log(value + 1) / :math.log(max + 1)
  end

  @doc """
  Calculates cultural impact score from components.
  Used for in-memory calculations.
  """
  def calculate_cultural_impact(canonical_count, popularity_value) do
    canonical_score = (canonical_count || 0) * canonical_sources_weight()
    popularity_score = normalize_popularity(popularity_value)
    
    min(1.0, canonical_score + popularity_score)
  end
end