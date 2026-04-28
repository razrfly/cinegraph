defmodule Cinegraph.Repo.Migrations.UpgradeObanToV14 do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 11)
  end
end
