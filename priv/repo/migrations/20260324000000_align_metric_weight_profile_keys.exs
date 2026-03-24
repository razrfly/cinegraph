defmodule Cinegraph.Repo.Migrations.AlignMetricWeightProfileKeys do
  use Ecto.Migration

  def up do
    execute """
    UPDATE metric_weight_profiles
    SET category_weights = (
      category_weights
      - 'awards' - 'financial' - 'cultural' - 'people'
      || CASE WHEN category_weights ? 'awards'
              THEN jsonb_build_object('industry_recognition', category_weights->'awards')
              ELSE '{}' END
      || CASE WHEN category_weights ? 'financial'
              THEN jsonb_build_object('financial_performance', category_weights->'financial')
              ELSE '{}' END
      || CASE WHEN category_weights ? 'cultural'
              THEN jsonb_build_object('cultural_impact', category_weights->'cultural')
              ELSE '{}' END
      || CASE WHEN category_weights ? 'people'
              THEN jsonb_build_object('people_quality', category_weights->'people')
              ELSE '{}' END
    )
    WHERE category_weights ? 'awards'
       OR category_weights ? 'financial'
       OR category_weights ? 'cultural'
       OR category_weights ? 'people'
    """
  end

  def down do
    execute """
    UPDATE metric_weight_profiles
    SET category_weights = (
      category_weights
      - 'industry_recognition' - 'financial_performance' - 'cultural_impact' - 'people_quality'
      || CASE WHEN category_weights ? 'industry_recognition'
              THEN jsonb_build_object('awards', category_weights->'industry_recognition')
              ELSE '{}' END
      || CASE WHEN category_weights ? 'financial_performance'
              THEN jsonb_build_object('financial', category_weights->'financial_performance')
              ELSE '{}' END
      || CASE WHEN category_weights ? 'cultural_impact'
              THEN jsonb_build_object('cultural', category_weights->'cultural_impact')
              ELSE '{}' END
      || CASE WHEN category_weights ? 'people_quality'
              THEN jsonb_build_object('people', category_weights->'people_quality')
              ELSE '{}' END
    )
    WHERE category_weights ? 'industry_recognition'
       OR category_weights ? 'financial_performance'
       OR category_weights ? 'cultural_impact'
       OR category_weights ? 'people_quality'
    """
  end
end
