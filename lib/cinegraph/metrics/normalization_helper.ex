defmodule Cinegraph.Metrics.NormalizationHelper do
  @moduledoc """
  Centralized normalization functions for metrics across the application.
  Provides consistent normalization strategies aligned with the metrics system documentation.
  """

  @doc """
  Returns the SQL fragment for normalizing TMDb popularity score using logarithmic normalization.
  This follows the documented approach: log(x+1)/log(threshold+1)

  ## Parameters
    - threshold: The threshold value for normalization (default: 1000 as per metric_definitions)

  ## Example
      fragment(NormalizationHelper.tmdb_popularity_sql(), ^movie_id)
  """
  def tmdb_popularity_sql(_threshold \\ 1000) do
    """
    COALESCE(
      (SELECT CASE 
        WHEN value IS NULL OR value = 0 THEN 0
        ELSE LN(value + 1) / LN(? + 1)
      END
      FROM external_metrics 
      WHERE movie_id = ? 
        AND source = 'tmdb' 
        AND metric_type = 'popularity_score' 
      LIMIT 1), 
      0
    )
    """
  end

  @doc """
  Returns the SQL fragment for calculating canonical sources impact.
  Uses a configurable weight multiplier for each canonical source.

  ## Parameters
    - weight: The weight multiplier for each canonical source (default: 0.1)
  """
  def canonical_sources_sql(_weight \\ 0.1) do
    """
    COALESCE(
      (SELECT COUNT(*) * ?
       FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 
      0
    )
    """
  end

  @doc """
  Returns the complete SQL fragment for cultural impact calculation.
  Combines TMDb popularity (log-normalized) and canonical sources presence.

  ## Parameters
    - canonical_weight: Weight for canonical sources (default: 0.1)
    - popularity_threshold: Threshold for TMDb popularity normalization (default: 1000)
    - max_value: Maximum value cap for the result (default: 1.0)
  """
  def cultural_impact_sql(opts \\ []) do
    canonical_weight = Keyword.get(opts, :canonical_weight, 0.1)
    popularity_threshold = Keyword.get(opts, :popularity_threshold, 1000)
    max_value = Keyword.get(opts, :max_value, 1.0)

    """
    COALESCE(
      LEAST(#{max_value}, 
        COALESCE(
          (SELECT COUNT(*) * #{canonical_weight}
           FROM jsonb_each(COALESCE(?, '{}'::jsonb))), 
          0
        ) + 
        COALESCE(
          (SELECT CASE 
            WHEN value IS NULL OR value = 0 THEN 0
            ELSE LN(value + 1) / LN(#{popularity_threshold} + 1)
          END
          FROM external_metrics 
          WHERE movie_id = ? 
            AND source = 'tmdb' 
            AND metric_type = 'popularity_score' 
          LIMIT 1), 
          0
        )
      ), 
      0
    )
    """
  end

  @doc """
  Normalizes a value using logarithmic normalization.
  Formula: log(value + 1) / log(threshold + 1)

  ## Examples
      iex> NormalizationHelper.logarithmic_normalize(100, 1000)
      0.6648
      
      iex> NormalizationHelper.logarithmic_normalize(1000, 1000)
      1.0
      
      iex> NormalizationHelper.logarithmic_normalize(0, 1000)
      0.0
  """
  def logarithmic_normalize(value, threshold)
      when is_number(value) and is_number(threshold) and threshold > 0 do
    if value <= 0 do
      0.0
    else
      :math.log(value + 1) / :math.log(threshold + 1)
    end
  end

  @doc """
  Normalizes a value using linear normalization.
  Formula: value / max_value

  ## Examples
      iex> NormalizationHelper.linear_normalize(50, 100)
      0.5
      
      iex> NormalizationHelper.linear_normalize(100, 100)
      1.0
  """
  def linear_normalize(value, max_value)
      when is_number(value) and is_number(max_value) and max_value > 0 do
    min(value / max_value, 1.0)
  end

  @doc """
  Configuration for cultural impact weights.
  Can be overridden via application config.
  """
  def cultural_impact_config do
    %{
      canonical_weight: Application.get_env(:cinegraph, :canonical_weight, 0.1),
      popularity_threshold: Application.get_env(:cinegraph, :popularity_threshold, 1000),
      max_value: Application.get_env(:cinegraph, :max_cap, 1.0)
    }
  end
end
