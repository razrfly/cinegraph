defmodule Cinegraph.Movies.DiscoveryScoringSimple do
  @moduledoc """
  Simplified Tunable Movie Discovery System using materialized scores.

  This version pre-calculates component scores for better performance and
  can use either database-driven weight profiles or custom weight maps.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Movies.DiscoveryCommon
  alias Cinegraph.Metrics.ScoringService

  @default_weights DiscoveryCommon.default_weights()

  @doc """
  Applies discovery scoring to a movie query with user-defined weights.
  Can accept either a weight map (legacy) or a profile name (database-driven).
  """
  def apply_scoring(query, weights \\ @default_weights, options \\ %{})

  # Handle database profile by name
  def apply_scoring(query, profile_name, options) when is_binary(profile_name) do
    ScoringService.apply_scoring(query, profile_name, options)
  end

  # Handle database profile struct
  def apply_scoring(query, %Cinegraph.Metrics.MetricWeightProfile{} = profile, options) do
    ScoringService.apply_scoring(query, profile, options)
  end

  # New-style weight map with mob/critics — delegate to ScoringService
  def apply_scoring(query, weights, options)
      when is_map(weights) and is_map_key(weights, :mob) do
    synthetic_profile = %Cinegraph.Metrics.MetricWeightProfile{
      name: "Custom",
      category_weights: %{
        "mob" => Map.get(weights, :mob, 0.1),
        "critics" => Map.get(weights, :critics, 0.1),
        "festival_recognition" => Map.get(weights, :festival_recognition, 0.2),
        "time_machine" => Map.get(weights, :time_machine, 0.2),
        "auteurs" => Map.get(weights, :auteurs, 0.2),
        "box_office" => Map.get(weights, :box_office, 0.2)
      },
      weights: %{},
      active: true,
      is_default: false
    }

    ScoringService.apply_scoring(query, synthetic_profile, options)
  end

  @doc """
  Returns scoring presets for common use cases.
  Now fetches from database instead of hard-coded values.
  """
  def get_presets do
    # Try to get from database first
    case ScoringService.get_all_profiles() do
      [] ->
        # Fallback to hard-coded if database is empty
        DiscoveryCommon.get_presets()

      profiles ->
        # Convert database profiles to discovery format
        profiles
        |> Enum.map(fn profile ->
          key =
            profile.name
            |> String.downcase()
            |> String.replace(" ", "_")

          weights = ScoringService.profile_to_discovery_weights(profile)
          {key, weights}
        end)
        |> Enum.into(%{})
    end
  end
end
