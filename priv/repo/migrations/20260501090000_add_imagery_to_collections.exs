defmodule Cinegraph.Repo.Migrations.AddImageryToCollections do
  use Ecto.Migration

  def change do
    alter table(:movie_lists) do
      add :cover_image_url, :text
      add :hero_image_url, :text
    end

    alter table(:festival_organizations) do
      add :logo_url, :text
      add :hero_image_url, :text
    end
  end
end
