defmodule Cinegraph.Repo.Migrations.CreatePredictionPreRegistrations do
  use Ecto.Migration

  # #1036 Session 2 (Layer 2): the Prediction Integrity Protocol Rule-1 artifact —
  # the hypothesis registered BEFORE a model is trained (expected features, accuracy
  # range, failure threshold). Created here as the FK target for prediction_models;
  # enforcement (train refuses without a prereg) is Session 3.
  def change do
    create table(:prediction_pre_registrations) do
      add :source_key, :string, null: false
      add :expected_top_features, :map, null: false, default: %{}
      add :expected_accuracy_range, :map, null: false, default: %{}
      add :failure_threshold, :text
      add :notes, :text
      timestamps()
    end

    create index(:prediction_pre_registrations, [:source_key])
  end
end
