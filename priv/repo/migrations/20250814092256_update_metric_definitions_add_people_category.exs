defmodule Cinegraph.Repo.Migrations.UpdateMetricDefinitionsAddPeopleCategory do
  use Ecto.Migration

  def change do
    # This migration doesn't actually need to modify the database structure
    # since the category field is already a string. We just need to update
    # the schema validation in the code.
    
    # However, we can add an index for better query performance
    create index(:metric_definitions, [:category, :subcategory])
  end
end