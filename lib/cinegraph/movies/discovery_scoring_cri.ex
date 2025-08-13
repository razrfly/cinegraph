defmodule Cinegraph.Movies.DiscoveryScoringCRI do
  @moduledoc """
  CRI-based Movie Discovery System
  
  Replaces the hardcoded discovery scoring with the flexible CRI system.
  This module provides a compatibility layer to use CRI scores with the 
  existing discovery tuner interface.
  """
  
  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.{CRI, CRIScore, WeightProfile}
  alias Cinegraph.Movies.Movie
  
  @doc """
  Applies CRI-based discovery scoring to a movie query.
  
  The weights parameter maps the old discovery dimensions to CRI dimensions:
  - popular_opinion -> public weight
  - critical_acclaim -> artistic_impact weight  
  - industry_recognition -> institutional weight
  - cultural_impact -> (timelessness + cultural_penetration) / 2
  """
  def apply_scoring(query, weights \\ default_weights(), options \\ %{}) do
    # Convert old weights to CRI dimension weights
    cri_weights = convert_weights_to_cri(weights)
    min_score = Map.get(options, :min_score, 0.0)
    
    # Find or create a temporary profile with these weights
    profile = get_or_create_temp_profile(cri_weights)
    
    # Apply CRI scoring
    from m in query,
      join: cs in CRIScore,
      on: cs.movie_id == m.id and cs.profile_id == ^profile.id,
      where: cs.total_cri_score >= ^min_score,
      order_by: [desc: cs.total_cri_score],
      select_merge: %{
        discovery_score: cs.total_cri_score,
        score_components: %{
          popular_opinion: cs.public_score * ^weights.popular_opinion,
          critical_acclaim: cs.artistic_impact_score * ^weights.critical_acclaim,
          industry_recognition: cs.institutional_score * ^weights.industry_recognition,
          cultural_impact: ((cs.timelessness_score + cs.cultural_penetration_score) / 2.0) * ^weights.cultural_impact
        }
      }
  end
  
  @doc """
  Calculates CRI-based scores for a specific movie.
  Returns scores mapped to old discovery dimensions for compatibility.
  """
  def calculate_movie_scores(movie_id) do
    # Use balanced profile for individual score calculation
    case CRI.calculate_score(movie_id, "balanced") do
      {:ok, score} ->
        %{
          popular_opinion: score.public_score,
          critical_acclaim: score.artistic_impact_score,
          industry_recognition: score.institutional_score,
          cultural_impact: (score.timelessness_score + score.cultural_penetration_score) / 2.0
        }
      {:error, _} ->
        %{
          popular_opinion: 0.0,
          critical_acclaim: 0.0,
          industry_recognition: 0.0,
          cultural_impact: 0.0
        }
    end
  end
  
  @doc """
  Returns scoring presets mapped from CRI profiles.
  """
  def get_presets do
    %{
      balanced: default_weights(),
      critics_choice: %{
        popular_opinion: 0.1,
        critical_acclaim: 0.5,
        industry_recognition: 0.3,
        cultural_impact: 0.1
      },
      crowd_pleaser: %{
        popular_opinion: 0.6,
        critical_acclaim: 0.1,
        industry_recognition: 0.1,
        cultural_impact: 0.2
      },
      hidden_gems: %{
        popular_opinion: 0.2,
        critical_acclaim: 0.3,
        industry_recognition: 0.2,
        cultural_impact: 0.3
      },
      festival_circuit: %{
        popular_opinion: 0.1,
        critical_acclaim: 0.2,
        industry_recognition: 0.5,
        cultural_impact: 0.2
      }
    }
  end
  
  @doc """
  Triggers background recalculation of CRI scores for all movies.
  This should be called when switching to CRI-based discovery.
  """
  def migrate_to_cri_scoring do
    profiles = CRI.list_weight_profiles()
    
    Task.start(fn ->
      # Get all movies with metrics
      movies = 
        from(m in Movie,
          join: metric in Cinegraph.Metrics.Metric,
          on: metric.movie_id == m.id,
          group_by: m.id,
          having: count(metric.id) > 0,
          select: m
        )
        |> Repo.all()
      
      total = length(movies)
      
      # Calculate scores for each profile
      Enum.each(profiles, fn profile ->
        IO.puts("Calculating CRI scores for profile: #{profile.name}")
        
        movies
        |> Enum.with_index(1)
        |> Enum.each(fn {movie, index} ->
          CRI.calculate_score(movie.id, profile.id)
          
          if rem(index, 100) == 0 do
            IO.puts("  Progress: #{index}/#{total} movies processed")
          end
        end)
      end)
      
      IO.puts("CRI score migration complete!")
    end)
  end
  
  # Private functions
  
  defp default_weights do
    %{
      popular_opinion: 0.25,
      critical_acclaim: 0.25,
      industry_recognition: 0.25,
      cultural_impact: 0.25
    }
  end
  
  defp convert_weights_to_cri(weights) do
    # Normalize weights
    total = 
      weights.popular_opinion + 
      weights.critical_acclaim + 
      weights.industry_recognition + 
      weights.cultural_impact
    
    if total == 0 do
      %{
        timelessness_weight: 0.2,
        cultural_penetration_weight: 0.2,
        artistic_impact_weight: 0.2,
        institutional_weight: 0.2,
        public_weight: 0.2
      }
    else
      # Map old dimensions to CRI dimensions
      %{
        public_weight: weights.popular_opinion / total,
        artistic_impact_weight: weights.critical_acclaim / total,
        institutional_weight: weights.industry_recognition / total,
        # Split cultural_impact between timelessness and cultural_penetration
        timelessness_weight: (weights.cultural_impact / 2.0) / total,
        cultural_penetration_weight: (weights.cultural_impact / 2.0) / total
      }
    end
  end
  
  defp get_or_create_temp_profile(cri_weights) do
    # Check if a profile with these exact weights exists
    existing = 
      Repo.one(
        from wp in WeightProfile,
          where: wp.timelessness_weight == ^cri_weights.timelessness_weight and
                 wp.cultural_penetration_weight == ^cri_weights.cultural_penetration_weight and
                 wp.artistic_impact_weight == ^cri_weights.artistic_impact_weight and
                 wp.institutional_weight == ^cri_weights.institutional_weight and
                 wp.public_weight == ^cri_weights.public_weight and
                 wp.active == true,
          limit: 1
      )
    
    case existing do
      nil ->
        # Create a temporary profile
        {:ok, profile} = CRI.create_weight_profile(%{
          name: "temp_discovery_#{:rand.uniform(10000)}",
          description: "Temporary profile for discovery tuner",
          profile_type: "manual",
          active: true,
          is_system: false,
          timelessness_weight: cri_weights.timelessness_weight,
          cultural_penetration_weight: cri_weights.cultural_penetration_weight,
          artistic_impact_weight: cri_weights.artistic_impact_weight,
          institutional_weight: cri_weights.institutional_weight,
          public_weight: cri_weights.public_weight,
          metric_weights: %{}
        })
        profile
      
      profile ->
        profile
    end
  end
end