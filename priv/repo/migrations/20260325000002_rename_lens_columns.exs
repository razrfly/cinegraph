defmodule Cinegraph.Repo.Migrations.RenameLensColumns do
  use Ecto.Migration

  def up do
    # Rename 4 columns in movie_score_caches
    rename table(:movie_score_caches), :ivory_tower_score, to: :critics_score
    rename table(:movie_score_caches), :cultural_impact_score, to: :time_machine_score
    rename table(:movie_score_caches), :financial_performance_score, to: :box_office_score
    rename table(:movie_score_caches), :people_quality_score, to: :auteurs_score

    # Data migration: rename JSONB keys in metric_weight_profiles.category_weights
    execute """
      UPDATE metric_weight_profiles
      SET category_weights = (
        category_weights
        - 'ivory_tower' - 'cultural_impact' - 'financial_performance' - 'people_quality'
        || jsonb_strip_nulls(jsonb_build_object(
             'critics',       category_weights->'ivory_tower',
             'time_machine',  category_weights->'cultural_impact',
             'box_office',    category_weights->'financial_performance',
             'auteurs',       category_weights->'people_quality'
           ))
      )
      WHERE category_weights ?| ARRAY['ivory_tower','cultural_impact','financial_performance','people_quality']
    """

    # Data migration: rename category values in metric_definitions
    execute "UPDATE metric_definitions SET category = 'critics'      WHERE category = 'ivory_tower'"

    execute "UPDATE metric_definitions SET category = 'time_machine' WHERE category = 'cultural_impact'"

    execute "UPDATE metric_definitions SET category = 'box_office'   WHERE category = 'financial_performance'"

    execute "UPDATE metric_definitions SET category = 'auteurs'      WHERE category = 'people_quality'"
  end

  def down do
    # Reverse column renames
    rename table(:movie_score_caches), :critics_score, to: :ivory_tower_score
    rename table(:movie_score_caches), :time_machine_score, to: :cultural_impact_score
    rename table(:movie_score_caches), :box_office_score, to: :financial_performance_score
    rename table(:movie_score_caches), :auteurs_score, to: :people_quality_score

    # Reverse JSONB key renames
    execute """
      UPDATE metric_weight_profiles
      SET category_weights = (
        category_weights
        - 'critics' - 'time_machine' - 'box_office' - 'auteurs'
        || jsonb_strip_nulls(jsonb_build_object(
             'ivory_tower',          category_weights->'critics',
             'cultural_impact',      category_weights->'time_machine',
             'financial_performance', category_weights->'box_office',
             'people_quality',       category_weights->'auteurs'
           ))
      )
      WHERE category_weights ?| ARRAY['critics','time_machine','box_office','auteurs']
    """

    # Reverse category value renames
    execute "UPDATE metric_definitions SET category = 'ivory_tower'          WHERE category = 'critics'"

    execute "UPDATE metric_definitions SET category = 'cultural_impact'      WHERE category = 'time_machine'"

    execute "UPDATE metric_definitions SET category = 'financial_performance' WHERE category = 'box_office'"

    execute "UPDATE metric_definitions SET category = 'people_quality'       WHERE category = 'auteurs'"
  end
end
