defmodule Cinegraph.Repo.Migrations.FixMetricWeightProfiles do
  use Ecto.Migration

  def up do
    # Fix Balanced profile to use true 25% for each of the 4 categories
    # Since popular_opinion now includes all rating sources (merged with critical_acclaim)
    execute """
      UPDATE metric_weight_profiles
      SET 
        category_weights = jsonb_build_object(
          'popular_opinion', 0.25,
          'awards', 0.25,
          'cultural', 0.25,
          'people', 0.25,
          'financial', 0.0
        ),
        description = 'Equal weight across all four dimensions: popular opinion (25%), industry recognition (25%), cultural impact (25%), and people quality (25%)',
        updated_at = NOW()
      WHERE name = 'Balanced'
    """

    # Fix Crowd Pleaser profile - align description with actual weights (45%)
    execute """
      UPDATE metric_weight_profiles
      SET 
        description = 'Focuses on popular opinion (45%), cultural impact (30%), minimal awards (10%), financial success (10%), people quality (5%)',
        updated_at = NOW()
      WHERE name = 'Crowd Pleaser'
    """

    # Update Award Winner profile to maintain balance after critical_acclaim removal
    execute """
      UPDATE metric_weight_profiles
      SET 
        category_weights = jsonb_build_object(
          'popular_opinion', 0.25,
          'awards', 0.45,
          'cultural', 0.2,
          'people', 0.1,
          'financial', 0.0
        ),
        updated_at = NOW()
      WHERE name = 'Award Winner'
    """

    # Update Critics Choice profile - now focuses on all rating sources equally
    # Since we no longer distinguish between "critic" and "audience" ratings
    execute """
      UPDATE metric_weight_profiles
      SET 
        description = 'Prioritizes rating platforms (50% across IMDb, TMDb, Metacritic, RT) with cultural impact (30%), some awards (15%), minimal people (5%)',
        updated_at = NOW()
      WHERE name = 'Critics Choice'
    """
  end

  def down do
    # Revert Balanced profile
    execute """
      UPDATE metric_weight_profiles
      SET 
        category_weights = jsonb_build_object(
          'popular_opinion', 0.4,
          'awards', 0.2,
          'cultural', 0.2,
          'people', 0.2,
          'financial', 0.0
        ),
        description = 'Equal weight across popular opinion, cultural impact, industry recognition, and people quality',
        updated_at = NOW()
      WHERE name = 'Balanced'
    """

    # Revert Crowd Pleaser description
    execute """
      UPDATE metric_weight_profiles
      SET 
        description = 'Focuses on popular opinion (40% with IMDb/TMDb weighted higher), cultural impact (35%), minimal awards (10%), financial success (10%)',
        updated_at = NOW()
      WHERE name = 'Crowd Pleaser'
    """

    # Revert Critics Choice description
    execute """
      UPDATE metric_weight_profiles
      SET 
        description = 'Prioritizes critic-favored platforms (50% ratings with Metacritic/RT weighted higher) with cultural impact (30%), some awards (15%), minimal people (5%)',
        updated_at = NOW()
      WHERE name = 'Critics Choice'
    """
  end
end