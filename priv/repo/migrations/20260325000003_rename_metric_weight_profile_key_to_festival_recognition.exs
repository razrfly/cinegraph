defmodule Cinegraph.Repo.Migrations.RenameMetricWeightProfileKeyToFestivalRecognition do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE metric_weight_profiles
    SET category_weights = category_weights - 'industry_recognition'
      || jsonb_build_object('festival_recognition', category_weights->'industry_recognition')
    WHERE category_weights ? 'industry_recognition'
    """)
  end

  def down do
    execute("""
    UPDATE metric_weight_profiles
    SET category_weights = category_weights - 'festival_recognition'
      || jsonb_build_object('industry_recognition', category_weights->'festival_recognition')
    WHERE category_weights ? 'festival_recognition'
    """)
  end
end
