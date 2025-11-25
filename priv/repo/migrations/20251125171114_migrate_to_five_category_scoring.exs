defmodule Cinegraph.Repo.Migrations.MigrateToFiveCategoryScoring do
  use Ecto.Migration

  @moduledoc """
  Migrates the scoring system to use 5 standard categories:
  1. Popular Opinion - Ratings from IMDb, TMDb, Metacritic, Rotten Tomatoes
  2. Industry Recognition (awards) - Festival wins and nominations
  3. Cultural Impact - Canonical sources and cultural significance
  4. People Quality - Quality scores of cast and crew
  5. Financial Performance - Revenue and budget performance

  Removes the "collaboration_intelligence" category and updates all profiles
  to use the new 5-category system with appropriate weights.
  """

  def up do
    # Update Balanced profile to use equal 20% weights across all 5 categories
    execute """
      UPDATE metric_weight_profiles
      SET
        category_weights = jsonb_build_object(
          'popular_opinion', 0.20,
          'awards', 0.20,
          'cultural', 0.20,
          'people', 0.20,
          'financial', 0.20
        ),
        description = 'Equal weight across all five categories: popular opinion (20%), industry recognition (20%), cultural impact (20%), people quality (20%), and financial performance (20%)',
        updated_at = NOW()
      WHERE name = 'Balanced'
    """

    # Update Crowd Pleaser to emphasize popular opinion and financial success
    execute """
      UPDATE metric_weight_profiles
      SET
        category_weights = jsonb_build_object(
          'popular_opinion', 0.35,
          'awards', 0.10,
          'cultural', 0.25,
          'people', 0.10,
          'financial', 0.20
        ),
        description = 'Focuses on popular opinion (35%), cultural impact (25%), financial success (20%), with minimal awards (10%) and people quality (10%)',
        updated_at = NOW()
      WHERE name = 'Crowd Pleaser'
    """

    # Update Award Winner to emphasize industry recognition
    execute """
      UPDATE metric_weight_profiles
      SET
        category_weights = jsonb_build_object(
          'popular_opinion', 0.20,
          'awards', 0.40,
          'cultural', 0.20,
          'people', 0.15,
          'financial', 0.05
        ),
        description = 'Prioritizes industry recognition (40%), with balanced popular opinion (20%), cultural impact (20%), people quality (15%), and minimal financial focus (5%)',
        updated_at = NOW()
      WHERE name = 'Award Winner'
    """

    # Update Critics Choice to emphasize ratings and cultural impact
    execute """
      UPDATE metric_weight_profiles
      SET
        category_weights = jsonb_build_object(
          'popular_opinion', 0.40,
          'awards', 0.15,
          'cultural', 0.30,
          'people', 0.10,
          'financial', 0.05
        ),
        description = 'Prioritizes popular opinion across all rating platforms (40%), cultural impact (30%), some industry recognition (15%), people quality (10%), minimal financial (5%)',
        updated_at = NOW()
      WHERE name = 'Critics Choice'
    """

    # Create new Blockbuster profile that emphasizes financial performance
    execute """
      INSERT INTO metric_weight_profiles (name, description, category_weights, weights, active, is_default, is_system, inserted_at, updated_at)
      VALUES (
        'Blockbuster',
        'Emphasizes financial performance (40%), popular opinion (25%), with balanced cultural impact (15%), industry recognition (10%), and people quality (10%)',
        jsonb_build_object(
          'popular_opinion', 0.25,
          'awards', 0.10,
          'cultural', 0.15,
          'people', 0.10,
          'financial', 0.40
        ),
        '{}'::jsonb,
        true,
        false,
        true,
        NOW(),
        NOW()
      )
      ON CONFLICT (name) DO UPDATE SET
        category_weights = EXCLUDED.category_weights,
        description = EXCLUDED.description,
        updated_at = NOW()
    """

    # Create new Auteur profile that emphasizes people quality and cultural impact
    execute """
      INSERT INTO metric_weight_profiles (name, description, category_weights, weights, active, is_default, is_system, inserted_at, updated_at)
      VALUES (
        'Auteur',
        'Focuses on people quality (35%), cultural impact (30%), popular opinion (20%), industry recognition (15%), minimal financial (0%)',
        jsonb_build_object(
          'popular_opinion', 0.20,
          'awards', 0.15,
          'cultural', 0.30,
          'people', 0.35,
          'financial', 0.00
        ),
        '{}'::jsonb,
        true,
        false,
        true,
        NOW(),
        NOW()
      )
      ON CONFLICT (name) DO UPDATE SET
        category_weights = EXCLUDED.category_weights,
        description = EXCLUDED.description,
        updated_at = NOW()
    """
  end

  def down do
    # Revert Balanced profile to previous 4-category system
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

    # Revert Crowd Pleaser
    execute """
      UPDATE metric_weight_profiles
      SET
        category_weights = jsonb_build_object(
          'popular_opinion', 0.45,
          'awards', 0.10,
          'cultural', 0.30,
          'people', 0.05,
          'financial', 0.10
        ),
        description = 'Focuses on popular opinion (45%), cultural impact (30%), minimal awards (10%), financial success (10%), people quality (5%)',
        updated_at = NOW()
      WHERE name = 'Crowd Pleaser'
    """

    # Revert Award Winner
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

    # Revert Critics Choice
    execute """
      UPDATE metric_weight_profiles
      SET
        category_weights = jsonb_build_object(
          'popular_opinion', 0.50,
          'awards', 0.15,
          'cultural', 0.30,
          'people', 0.05,
          'financial', 0.0
        ),
        description = 'Prioritizes rating platforms (50% across IMDb, TMDb, Metacritic, RT) with cultural impact (30%), some awards (15%), minimal people (5%)',
        updated_at = NOW()
      WHERE name = 'Critics Choice'
    """

    # Remove new profiles
    execute "DELETE FROM metric_weight_profiles WHERE name IN ('Blockbuster', 'Auteur')"
  end
end
