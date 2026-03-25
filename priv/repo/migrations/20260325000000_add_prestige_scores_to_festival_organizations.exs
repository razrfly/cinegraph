defmodule Cinegraph.Repo.Migrations.AddPrestigeScoresToFestivalOrganizations do
  use Ecto.Migration

  def change do
    alter table(:festival_organizations) do
      add :win_score, :float
      add :nom_score, :float
      add :prestige_tier, :integer
    end
  end
end
