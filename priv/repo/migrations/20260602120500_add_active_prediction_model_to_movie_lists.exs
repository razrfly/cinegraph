defmodule Cinegraph.Repo.Migrations.AddActivePredictionModelToMovieLists do
  use Ecto.Migration

  # #1036 Session 2: point a list at its active trained model + record its backtest
  # strategy. `trained_weights` (existing) becomes a derived read-cache of the active
  # model's weights.
  def change do
    alter table(:movie_lists) do
      add :active_prediction_model_id, references(:prediction_models, on_delete: :nilify_all)
      add :backtest_strategy, :string
    end

    create index(:movie_lists, [:active_prediction_model_id])
  end
end
