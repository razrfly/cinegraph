defmodule Cinegraph.Repo.Migrations.RenameCalibrationScoringConfigKeys do
  use Ecto.Migration

  @doc """
  Renames legacy category keys in calibration_scoring_configurations
  to the current naming convention used in @categories.

  Legacy → current:
    popular_opinion        → mob
    industry_recognition   → festival_recognition
    financial_performance  → box_office
    cultural_impact        → time_machine
    people_quality         → auteurs
  """
  def up do
    execute("""
    UPDATE calibration_scoring_configurations
    SET category_weights = (
      category_weights
      - 'popular_opinion' - 'industry_recognition' - 'financial_performance'
      - 'cultural_impact' - 'people_quality'
      || jsonb_strip_nulls(jsonb_build_object(
           'mob',                  category_weights->'popular_opinion',
           'festival_recognition', category_weights->'industry_recognition',
           'box_office',           category_weights->'financial_performance',
           'time_machine',         category_weights->'cultural_impact',
           'auteurs',              category_weights->'people_quality'
         ))
    )
    WHERE category_weights ?| ARRAY[
      'popular_opinion','industry_recognition','financial_performance',
      'cultural_impact','people_quality'
    ]
    """)

    execute("""
    UPDATE calibration_scoring_configurations
    SET missing_data_strategies = (
      missing_data_strategies
      - 'popular_opinion' - 'industry_recognition' - 'financial_performance'
      - 'cultural_impact' - 'people_quality'
      || jsonb_strip_nulls(jsonb_build_object(
           'mob',                  missing_data_strategies->'popular_opinion',
           'festival_recognition', missing_data_strategies->'industry_recognition',
           'box_office',           missing_data_strategies->'financial_performance',
           'time_machine',         missing_data_strategies->'cultural_impact',
           'auteurs',              missing_data_strategies->'people_quality'
         ))
    )
    WHERE missing_data_strategies ?| ARRAY[
      'popular_opinion','industry_recognition','financial_performance',
      'cultural_impact','people_quality'
    ]
    """)
  end

  def down do
    execute("""
    UPDATE calibration_scoring_configurations
    SET category_weights = (
      category_weights
      - 'mob' - 'festival_recognition' - 'box_office' - 'time_machine' - 'auteurs'
      || jsonb_strip_nulls(jsonb_build_object(
           'popular_opinion',      category_weights->'mob',
           'industry_recognition', category_weights->'festival_recognition',
           'financial_performance', category_weights->'box_office',
           'cultural_impact',      category_weights->'time_machine',
           'people_quality',       category_weights->'auteurs'
         ))
    )
    WHERE category_weights ?| ARRAY['mob','festival_recognition','box_office','time_machine','auteurs']
    """)

    execute("""
    UPDATE calibration_scoring_configurations
    SET missing_data_strategies = (
      missing_data_strategies
      - 'mob' - 'festival_recognition' - 'box_office' - 'time_machine' - 'auteurs'
      || jsonb_strip_nulls(jsonb_build_object(
           'popular_opinion',      missing_data_strategies->'mob',
           'industry_recognition', missing_data_strategies->'festival_recognition',
           'financial_performance', missing_data_strategies->'box_office',
           'cultural_impact',      missing_data_strategies->'time_machine',
           'people_quality',       missing_data_strategies->'auteurs'
         ))
    )
    WHERE missing_data_strategies ?| ARRAY['mob','festival_recognition','box_office','time_machine','auteurs']
    """)
  end
end
