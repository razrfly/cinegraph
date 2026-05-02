defmodule Cinegraph.Repo.Migrations.AddCompanyDisplayFields do
  use Ecto.Migration

  def change do
    alter table(:production_companies) do
      add :slug, :string
      add :description, :text
      add :website, :text
      add :logo_url, :text
      add :hero_image_url, :text
      add :metadata, :map, default: %{}, null: false
    end

    create unique_index(:production_companies, [:slug])
  end
end
