defmodule Cinegraph.Repo.Migrations.AddTrainedWeightsToMovieLists do
  use Ecto.Migration

  def change do
    alter table(:movie_lists) do
      add :trained_weights, :map, default: nil
    end
  end
end
