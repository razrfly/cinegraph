defmodule Cinegraph.Repo.Migrations.MakeMetricDefinitionsCategoryNullable do
  use Ecto.Migration

  # #1036: ML-only data points (runtime, genres, language, …) are catalogued
  # without a lens, so `category` must allow NULL.
  def up do
    alter table(:metric_definitions) do
      modify :category, :string, null: true
    end
  end

  def down do
    # The catalog now intentionally contains category-less (ML-only) rows; remove them
    # before restoring NOT NULL so the rollback can't fail.
    execute("DELETE FROM metric_definitions WHERE category IS NULL")

    alter table(:metric_definitions) do
      modify :category, :string, null: false
    end
  end
end
