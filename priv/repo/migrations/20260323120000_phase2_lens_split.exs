defmodule Cinegraph.Repo.Migrations.Phase2LensSplit do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE metric_weight_profiles
    SET category_weights = (
      category_weights
      - 'popular_opinion'
      || jsonb_build_object('mob',
           ROUND((COALESCE((category_weights->>'popular_opinion')::numeric, 0.2) / 2)::numeric, 4))
      || jsonb_build_object('ivory_tower',
           ROUND((COALESCE((category_weights->>'popular_opinion')::numeric, 0.2) / 2)::numeric, 4))
    )
    WHERE category_weights ? 'popular_opinion'
    """)
  end

  def down do
    execute("""
    UPDATE metric_weight_profiles
    SET category_weights = (
      category_weights
      - 'mob'
      - 'ivory_tower'
      || jsonb_build_object('popular_opinion',
           COALESCE((category_weights->>'mob')::numeric, 0)
           + COALESCE((category_weights->>'ivory_tower')::numeric, 0))
    )
    WHERE category_weights ? 'mob' OR category_weights ? 'ivory_tower'
    """)
  end
end
