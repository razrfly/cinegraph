defmodule Cinegraph.Repo.Migrations.AddSlugToFestivalOrganizations do
  use Ecto.Migration

  def up do
    alter table(:festival_organizations) do
      add :slug, :string
    end

    create unique_index(:festival_organizations, [:slug])

    # Populate slugs for existing organizations
    execute """
            UPDATE festival_organizations
            SET slug = CASE id
              WHEN 1 THEN 'oscars'
              WHEN 4 THEN 'cannes'
              WHEN 7 THEN 'sundance'
              ELSE LOWER(REPLACE(REPLACE(name, ' ', '-'), '''', ''))
            END
            WHERE slug IS NULL
            """
  end

  def down do
    drop unique_index(:festival_organizations, [:slug])

    alter table(:festival_organizations) do
      remove :slug
    end
  end
end
